'use strict'

import canonical from './imports/canonical.coffee'
import { ArrayMembers, ArrayWithLength, NumberInRange, NonEmptyString, IdOrObject, ObjectWith } from './imports/match.coffee'
import { IsMechanic } from './imports/mechanics.coffee'
import { getTag, isStuck, canonicalTags } from './imports/tags.coffee'
import { RoundUrlPrefix, PuzzleUrlPrefix } from './imports/settings.coffee'
if Meteor.isServer
  {newMessage, ensureDawnOfTime} = require('/server/imports/newMessage.coffee')
else
  newMessage = ->
  ensureDawnOfTime = ->
# Blackboard -- data model
# Loaded on both the client and the server

# how often we send keep alive presence messages.  increase/decrease to adjust
# client/server load.
PRESENCE_KEEPALIVE_MINUTES = 2

# this is used to yield "zero results" in collections which index by timestamp
NOT_A_TIMESTAMP = -9999

randomname = if Meteor.isServer
  (s) -> require('../server/imports/randomname.coffee').default(seed: s)
else
  (s) -> s.slice(0, 16)

BBCollection = Object.create(null) # create new object w/o any inherited cruft

# Names is a synthetic collection created by the server which indexes
# the names and ids of Rounds and Puzzles:
#   _id: mongodb id (of a element in Rounds or Puzzles)
#   type: string ("rounds", "puzzles")
#   name: string
#   canon: canonicalized version of name, for searching
Names = BBCollection.names = \
  if Meteor.isClient then new Mongo.Collection 'names' else null

# LastAnswer is a synthetic collection created by the server which gives the
# solution time of the most recently-solved puzzle.
#    _id: random UUID
#    solved: solution time
#    type: string ("puzzles" or "rounds")
#    target: id of most recently solved puzzle/round
LastAnswer = BBCollection.last_answer = \
  if Meteor.isClient then new Mongo.Collection 'last-answer' else null

# Rounds are:
#   _id: mongodb id
#   name: string
#   canon: canonicalized version of name, for searching
#   link: URL of the round on the hunt site
#   created: timestamp
#   created_by: canon of Nick
#   sort_key: timestamp. Initially created, but can be traded to other rounds.
#   touched: timestamp -- records edits to tag, order, group, etc.
#   touched_by: canon of Nick with last touch
#   solved:  timestamp -- null (not missing or zero) if not solved
#            (actual answer is in a tag w/ name "Answer")
#   solved_by:  timestamp of Nick who confirmed the answer
#   incorrectAnswers: [ { answer: "Wrong", who: "answer submitter",
#                         backsolve: ..., provided: ..., timestamp: ... }, ... ]
#   tags: status: { name: "Status", value: "stuck" }, ... 
#   puzzles: [ array of puzzle _ids, in order ]
#            Preserving order is why this is a list here and not a foreign key
#            in the puzzle.
Rounds = BBCollection.rounds = new Mongo.Collection "rounds"
if Meteor.isServer
  Rounds._ensureIndex {canon: 1}, {unique:true, dropDups:true}
  Rounds._ensureIndex {puzzles: 1}
  Rounds._ensureIndex {sort_key: 1}
  Rounds._ensureIndex {sort_key: -1}

# Puzzles are:
#   _id: mongodb id
#   name: string
#   canon: canonicalized version of name, for searching
#   link: URL of the puzzle on the hunt site
#   created: timestamp
#   created_by: canon of Nick
#   touched: timestamp
#   touched_by: canon of Nick with last touch
#   solved:  timestamp -- null (not missing or zero) if not solved
#            (actual answer is in a tag w/ name "Answer")
#   solved_by:  timestamp of Nick who confirmed the answer
#   incorrectAnswers: [ { answer: "Wrong", who: "answer submitter",
#                         backsolve: ..., provided: ..., timestamp: ... }, ... ]
#   tags: status: { name: "Status", value: "stuck" }, ... 
#   spreadsheet: optional google spreadsheet id
#   favorites: object whose keys are userids of users who favorited this
#              puzzle. Values are true. On the client, either empty or contains
#              only you.
#   mechanics: list of canonical forms of mechanic names from
#              ./imports/mechanics.coffee.
#   puzzles: array of puzzle _ids for puzzles that feed into this.
#            absent if this isn't a meta. empty if it is, but nothing feeds into
#            it yet.
#   feedsInto: array of puzzle ids for metapuzzles this feeds into. Can be empty.
#   if a has b in its feedsInto, then b should have a in its puzzles.
#   This is kept denormalized because the lack of indexes in Minimongo would
#   make it inefficient to query on the client, and because we want to control
#   the order within a meta.
#   Note that this allows arbitrarily many meta puzzles. Also, there is no
#   requirement that a meta be fed only by puzzles in the same round.
# If you add fields to this that should be visible on the client, also add them
# to the fields map in puzzleQuery in server/server.coffee.
Puzzles = BBCollection.puzzles = new Mongo.Collection "puzzles"
if Meteor.isServer
  Puzzles._ensureIndex {canon: 1}, {unique:true, dropDups:true}
  Puzzles._ensureIndex {feedsInto: 1}
  Puzzles._ensureIndex {puzzles: 1}

# Users are:
#   _id: canonical nickname
#   nickname (non-canonical form of _id)
#   real_name (optional)
#   gravatar (optional email address for avatar)
#   services: map of provider-specific stuff; hidden on client
#   favorite_mechanics: list of favorite mechanics in canonical form.
#     Only served to yourself.
if Meteor.isServer
  Meteor.users._ensureIndex { nickname: 1}
# if Meteor.isServer
#   Meteor.users._ensureIndex {priv_located_order: 1},
#     partialFilterExpression:
#       priv_located_order: { $exists: true }
#   # We don't push the index to the client, so it's okay to have it update
#   # frequently.
#   Meteor.users._ensureIndex {priv_located_at: '2dsphere'}, {}

# Messages
#   body: string
#   nick: canonicalized string (may match some Nicks.canon ... or not)
#   system: boolean (true for system messages, false for user messages)
#   action: boolean (true for /me commands)
#   oplog:  boolean (true for semi-automatic operation log message)
#   presence: optional string ('join'/'part' for presence-change only)
#   bot_ignore: optional boolean (true for messages from e.g. email or twitter)
#   to:   destination of pm (optional)
#   starred: boolean. Pins this message to the top of the puzzle page or blackboard.
#   room_name: "<type>/<id>", ie "puzzle/1", "round/1".
#                             "general/0" for main chat.
#                             "oplog/0" for the operation log.
#   timestamp: timestamp
#   useful: boolean (true for useful responses from bots; not set for "fun"
#                    bot messages and commands that trigger them.)
#   useless_cmd: boolean (true if this message triggered the bot to
#                         make a not-useful response)
#   dawn_of_time: boolean. True for the first message in each channel, which
#                 also has _id equal to the channel name.
#   deleted: boolean. True if message was deleted. 'Deleted' messages aren't
#            actually deleted because that could screw up the 'last read' line;
#            they're just not rendered.
#
# Messages which are part of the operation log have `nick`, `message`,
# and `timestamp` set to describe what was done, when, and by who.
# They have `system=false`, `action=true`, `oplog=true`, `to=null`,
# and `room_name="oplog/0"`.  They also have three additional fields:
# `type` and `id`, which give a mongodb reference to the object
# modified so we can hyperlink to it, and stream, which maps to the
# JS Notification API 'tag' for deduping and selective muting.
Messages = BBCollection.messages = new Mongo.Collection "messages"
if Meteor.isServer
  Messages._ensureIndex {to:1, room_name:1, timestamp:-1}, {}
  Messages._ensureIndex {nick:1, room_name:1, timestamp:-1}, {}
  Messages._ensureIndex {room_name:1, timestamp:-1}, {}
  Messages._ensureIndex {room_name:1, starred: -1, timestamp: 1},
    partialFilterExpression: starred: true
  Messages._ensureIndex {timestamp: 1}, {}

# Last read message for a user in a particular chat room
#   nick: canonicalized string, as in Messages
#   room_name: string, as in Messages
#   timestamp: timestamp of last read message
LastRead = BBCollection.lastread = new Mongo.Collection "lastread"
if Meteor.isServer
  LastRead._ensureIndex {nick:1, room_name:1}, {unique:true, dropDups:true}
  LastRead._ensureIndex {nick:1}, {} # be safe

# Chat room presence
#   nick: canonicalized string, as in Messages
#   room_name: string, as in Messages
#   timestamp: timestamp -- when user was last seen in room
#   foreground: boolean (true if user's tab is still in foreground)
#   foreground_uuid: identity of client with tab in foreground
#   present: boolean (true if user is present, false if not)
Presence = BBCollection.presence = new Mongo.Collection "presence"
if Meteor.isServer
  Presence._ensureIndex {nick: 1, room_name:1}, {unique:true, dropDups:true}
  Presence._ensureIndex {timestamp:-1}, {}
  Presence._ensureIndex {present:1, room_name:1}, {}

# Whiteboard message
#    There should only be one of these.
#    timestamp: timestamp of last update
#    content: Markdown content
Whiteboard = BBCollection.whiteboard = new Mongo.Collection "whiteboard"
if Meteor.isServer
  Whiteboard._ensureIndex {timestamp:1}, {}

# this reverses the name given to Mongo.Collection; that is the
# 'type' argument is the name of a server-side Mongo collection.
collection = (type) ->
  if Object::hasOwnProperty.call(BBCollection, type)
    BBCollection[type]
  else
    throw new Meteor.Error(400, "Bad collection type: "+type)

# pretty name for (one of) this collection
pretty_collection = (type) ->
  switch type
    when "oplogs" then "operation log"
    else type.replace(/s$/, '')

drive_id_to_link = (id) ->
  "https://docs.google.com/folder/d/#{id}/edit"
spread_id_to_link = (id) ->
  "https://docs.google.com/spreadsheets/d/#{id}/edit"
    
(->
  # private helpers, not exported
  unimplemented = -> throw new Meteor.Error(500, "Unimplemented")

  isDuplicateError = (error) ->
    Meteor.isServer and error?.name in ['MongoError', 'BulkWriteError'] and error?.code==11000

  # a key of BBCollection
  ValidType = Match.Where (x) ->
    check x, NonEmptyString
    Object::hasOwnProperty.call(BBCollection, x)
    
  oplog = (message, type="", id="", who="", stream="") ->
    Messages.insert
      room_name: 'oplog/0'
      nick: canonical(who)
      timestamp: UTCNow()
      body: message
      bodyIsHtml: false
      type:type
      id:id
      oplog: true
      followup: true
      action: true
      system: false
      to: null
      stream: stream

  newObject = (type, args, extra, options={}) ->
    check args, ObjectWith
      name: NonEmptyString
      who: NonEmptyString
    now = UTCNow()
    object =
      name: args.name
      canon: canonical(args.name) # for lookup
      created: now
      created_by: canonical(args.who)
      touched: now
      touched_by: canonical(args.who)
      tags: canonicalTags(args.tags or [], args.who)
    for own key,value of (extra or Object.create(null))
      object[key] = value
    try
      object._id = collection(type).insert object
    catch error
      if isDuplicateError error
        # duplicate key, fetch the real thing
        return collection(type).findOne({canon:canonical(args.name)})
      throw error # something went wrong, who knows what, pass it on
    unless options.suppressLog
      oplog "Added", type, object._id, args.who, \
          if type in ['puzzles', 'rounds'] \
              then 'new-puzzles' else ''
    return object

  renameObject = (type, args, options={}) ->
    check args, ObjectWith
      id: NonEmptyString
      name: NonEmptyString
      who: NonEmptyString
    now = UTCNow()

    # Only perform the rename and oplog if the name is changing
    # XXX: This is racy with updates to findOne().name.
    oldName = collection(type).findOne(args.id).name
    if oldName is args.name
      return false

    try
      collection(type).update args.id, $set:
        name: args.name
        canon: canonical(args.name)
        touched: now
        touched_by: canonical(args.who)
    catch error
      # duplicate name--bail out
      if isDuplicateError error
        return false
      throw error
    unless options.suppressLog
      oplog "Renamed", type, args.id, args.who
    if type in ['puzzles', 'rounds']
      share.discordBot.rename(oldName, args.name)
    return true

  deleteObject = (type, args, options={}) ->
    check type, ValidType
    check args, ObjectWith
      id: NonEmptyString
      who: NonEmptyString
    name = collection(type)?.findOne(args.id)?.name
    return false unless name
    unless options.suppressLog
      oplog "Deleted "+pretty_collection(type)+" "+name, \
          type, null, args.who
    collection(type).remove(args.id)
    if type == 'puzzles'
      share.discordBot.deleteVoiceChannel(name)
    return true

  setTagInternal = (updateDoc, args) ->
    check args, ObjectWith
      name: NonEmptyString
      value: Match.Any
      who: NonEmptyString
      now: Number
    updateDoc.$set ?= {}
    updateDoc.$set["tags.#{canonical(args.name)}"] = 
      name: args.name
      value: args.value
      touched: args.now
      touched_by: canonical(args.who)
    true

  deleteTagInternal = (updateDoc, name) ->
    check name, NonEmptyString
    updateDoc.$unset ?= {}
    updateDoc.$unset["tags.#{canonical(name)}"] = ''
    true

  newSheet = (id, name) ->
    check id, NonEmptyString
    check name, NonEmptyString
    return unless Meteor.isServer
    res = share.drive.createPuzzle name
    return unless res?
    Puzzles.update id, { $set:
      spreadsheet: res
    }

  renameSheet = (new_name, spreadsheet) ->
    check new_name, NonEmptyString
    check spreadsheet, Match.Optional(NonEmptyString)
    return unless Meteor.isServer
    share.drive.renamePuzzle(new_name, spreadsheet)

  deleteSheet = (sheet) ->
    check sheet, NonEmptyString
    return unless Meteor.isServer
    share.drive.deletePuzzle sheet

  moveWithinParent = (id, parentType, parentId, args) ->
    check id, NonEmptyString
    check parentType, ValidType
    check parentId, NonEmptyString
    loop
      parent = collection(parentType).findOne(parentId)
      ix = parent?.puzzles?.indexOf(id)
      return false unless ix?
      npos = ix
      npuzzles = (p for p in parent.puzzles when p != id)
      if args.pos?
        npos += args.pos
        return false if npos < 0
        return false if npos > npuzzles.length
      else if args.before?
        npos = npuzzles.indexOf args.before
        return false unless npos >= 0
      else if args.after?
        npos = 1 + npuzzles.indexOf args.after
        return false unless npos > 0
      else
        return false
      npuzzles.splice(npos, 0, id)
      return true if 0 < (collection(parentType).update {_id: parentId, puzzles: parent.puzzles}, $set:
        puzzles: npuzzles
        touched: UTCNow()
        touched_by: canonical(args.who))
      
  Meteor.methods
    newRound: (args) ->
      check @userId, NonEmptyString
      round_prefix = RoundUrlPrefix.get()
      link = if round_prefix
        round_prefix += '/' unless round_prefix.endsWith '/'
        "#{round_prefix}#{canonical(args.name)}"
      r = newObject "rounds", {args..., who: @userId},
        puzzles: []
        link: args.link or link
        sort_key: UTCNow()
      ensureDawnOfTime "rounds/#{r._id}"
      # TODO(torgen): create default meta
      r
    renameRound: (args) ->
      check @userId, NonEmptyString
      renameObject "rounds", {args..., who: @userId}
      # TODO(torgen): rename default meta
    deleteRound: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      # disallow deletion unless round.puzzles is empty
      # TODO(torgen): ...other than default meta
      rg = Rounds.findOne id
      return false unless rg? and rg?.puzzles?.length is 0
      deleteObject "rounds", {id, who: @userId}

    newPuzzle: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        round: Match.Optional NonEmptyString
        feedsInto: Match.Optional [NonEmptyString]
        puzzles: Match.Optional [NonEmptyString]
        mechanics: Match.Optional [IsMechanic]
      args.round = args.round or Rounds.findOne({}, {sort: { createdAt: -1 }})._id
      throw new Meteor.Error(404, "bad round") unless Rounds.findOne(args.round)?
      puzzle_prefix = PuzzleUrlPrefix.get()
      link = if puzzle_prefix
        puzzle_prefix += '/' unless puzzle_prefix.endsWith '/'
        "#{puzzle_prefix}#{canonical(args.name)}"
      feedsInto = args.feedsInto or []
      extra =
        incorrectAnswers: []
        solved: null
        solved_by: null
        spreadsheet: args.spreadsheet or null
        link: args.link or link
        feedsInto: feedsInto
      if args.puzzles?
        extra.puzzles = args.puzzles
      if args.mechanics?
        extra.mechanics = [new Set(args.mechanics)...]
      p = newObject "puzzles", {args..., who: @userId}, extra
      ensureDawnOfTime "puzzles/#{p._id}"
      if args.puzzles?
        Puzzles.update {_id: $in: args.puzzles},
          $addToSet: feedsInto: p._id
          $set:
            touched_by: p.touched_by
            touched: p.touched
        , multi: true
      if feedsInto.length > 0
        Puzzles.update {_id: $in: feedsInto},
          $addToSet: puzzles: p._id
          $set:
            touched_by: p.touched_by
            touched: p.touched
        , multi: true
      if args.round?
        Rounds.update args.round,
          $addToSet: puzzles: p._id
          $set:
            touched_by: p.touched_by
            touched: p.touched
      # create google sheet (server only)
      newSheet p._id, p.name
      # create Discord voice channel
      if Meteor.isServer
        round = Rounds.findOne(args.round)
        if round.name?
          share.discordBot.newVoiceChannel(round.name, p.name)
        else
          share.discordBot.newVoiceChannel("no round", p.name)
      return p
    renamePuzzle: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        id: NonEmptyString
        name: NonEmptyString
      # get drive ID (racy)
      p = Puzzles.findOne args.id
      spreadsheet = p?.spreadsheet
      result = renameObject "puzzles", {args..., who: @userId}
      # rename google sheet
      renameSheet args.name, spreadsheet
      return result
    deletePuzzle: (pid) ->
      check @userId, NonEmptyString
      check pid, NonEmptyString
      # get drive ID (racy)
      old = Puzzles.findOne pid
      now = UTCNow()
      drive = old?.drive
      # remove puzzle itself
      r = deleteObject "puzzles", {id: pid, who: @userId}
      # remove from all rounds
      Rounds.update { puzzles: pid },
        $pull: puzzles: pid
        $set:
          touched: now
          touched_by: @userId
      , multi: true
      # Remove from all metas
      Puzzles.update { puzzles: pid },
        $pull: puzzles: pid
        $set:
          touched: now
          touched_by: @userId
      , multi: true
      # Remove from all feedsInto lists
      Puzzles.update { feedsInto: pid },
        $pull: feedsInto: pid
        $set:
          touched: now
          touched_by: @userId
      , multi: true
      # delete google drive folder
      # deleteDriveFolder drive if drive?
      # XXX: delete chat room logs?
      return r

    makeMeta: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      now = UTCNow()
      # This only fails if, for some reason, puzzles is a list containing null.
      return 0 < Puzzles.update {_id: id, puzzles: null}, $set:
        puzzles: []
        touched: now
        touched_by: @userId

    makeNotMeta: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      now = UTCNow()
      return 0 < Puzzles.update {_id: id, puzzles: []},
        $unset: puzzles: ""
        $set:
          touched: now
          touched_by: @userId

    feedMeta: (puzzleId, metaId) ->
      check @userId, NonEmptyString
      check puzzleId, NonEmptyString
      check metaId, NonEmptyString
      throw new Meteor.Error(404, 'No such meta') unless Puzzles.findOne(metaId)?
      throw new Meteor.Error(404, 'No such puzzle') unless Puzzles.findOne(puzzleId)?
      now = UTCNow()
      Puzzles.update
        _id: puzzleId
        feedsInto: $ne: metaId
      ,
        $addToSet: feedsInto: metaId
        $set: 
          touched: now
          touched_by: @userId
      return 0 < Puzzles.update
        _id: metaId
        puzzles: $ne: puzzleId
      ,
        $addToSet: puzzles: puzzleId
        $set: 
          touched: now
          touched_by: @userId

    unfeedMeta: (puzzleId, metaId) ->
      check @userId, NonEmptyString
      check puzzleId, NonEmptyString
      check metaId, NonEmptyString
      throw new Meteor.Error(404, 'No such meta') unless Puzzles.findOne(metaId)?
      throw new Meteor.Error(404, 'No such puzzle') unless Puzzles.findOne(puzzleId)?
      now = UTCNow()
      Puzzles.update
        _id: puzzleId
        feedsInto: metaId
      ,
        $pull: feedsInto: metaId
        $set: 
          touched: now
          touched_by: @userId
      return 0 < Puzzles.update
        _id: metaId
        puzzles: puzzleId
      ,
        $pull: puzzles: puzzleId
        $set: 
          touched: now
          touched_by: @userId

    favoriteMechanic: (mechanic) ->
      check @userId, NonEmptyString
      check mechanic, IsMechanic
      n = Meteor.users.update @userId, $addToSet: favorite_mechanics: mechanic
      throw new Meteor.Error(400, "bad userId: #{@userId}") unless n > 0

    unfavoriteMechanic: (mechanic) ->
      check @userId, NonEmptyString
      check mechanic, IsMechanic
      n = Meteor.users.update @userId, $pull: favorite_mechanics: mechanic
      throw new Meteor.Error(400, "bad userId: #{@userId}") unless n > 0

    announce: (body) ->
      check @userId, NonEmptyString
      check body, NonEmptyString
      oplog body, null, null, @userId, 'announcements'

    newMessage: (args) ->
      check @userId, NonEmptyString
      check args,
        body: Match.Optional String
        bodyIsHtml: Match.Optional Boolean
        action: Match.Optional Boolean
        to: Match.Optional NonEmptyString
        room_name: Match.Optional NonEmptyString
        useful: Match.Optional Boolean
        bot_ignore: Match.Optional Boolean
        suppressLastRead: Match.Optional Boolean
      return if this.isSimulation # suppress flicker
      suppress = args.suppressLastRead
      delete args.suppressLastRead
      newMsg = {args..., nick: @userId}
      newMsg.body ?= ''
      newMsg.room_name ?= "general/0"
      newMsg = newMessage newMsg
      # update the user's 'last read' message to include this one
      # (doing it here allows us to use server timestamp on message)
      unless suppress
        Meteor.call 'updateLastRead',
          room_name: newMsg.room_name
          timestamp: newMsg.timestamp
      newMsg

    deleteMessage: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      Messages.update
        _id: id
        dawn_of_time: $ne: true
      ,
        $set: deleted: true

    setStarred: (id, starred) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      check starred, Boolean
      Messages.update (
        _id: id
        to: null
        system: $in: [false, null]
        action: $in: [false, null]
        oplog: $in: [false, null]
        presence: null
      ), $set: {starred: starred or null}

    updateLastRead: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        room_name: NonEmptyString
        timestamp: Number
      LastRead.upsert
        nick: @userId
        room_name: args.room_name
      , $max:
        timestamp: args.timestamp

    setPresence: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        room_name: NonEmptyString
        present: Match.Optional Boolean
        foreground: Match.Optional Boolean
        uuid: Match.Optional NonEmptyString
      # we're going to do the db operation only on the server, so that we
      # can safely use mongo's 'upsert' functionality.  otherwise
      # Meteor seems to get a little confused as it creates presence
      # entries on the client that don't exist on the server.
      # (meteor does better when it's reconciling the *contents* of
      # documents, not their existence) (this is also why we added the
      # 'presence' field instead of deleting entries outright when
      # a user goes away)
      # IN METEOR 0.6.6 upsert support was added to the client.  So let's
      # try to do this on both sides now.
      #return unless Meteor.isServer
      Presence.upsert
        nick: @userId
        room_name: args.room_name
      , $set:
          timestamp: UTCNow()
          present: args.present or false
      return unless args.present
      # only set foreground if true or foreground_uuid matches; this
      # prevents bouncing if user has two tabs open, and one is foregrounded
      # and the other is not.
      if args.foreground
        Presence.update
          nick: @userId
          room_name: args.room_name
        , $set:
          foreground: true
          foreground_uuid: args.uuid
      else # only update 'foreground' if uuid matches
        Presence.update
          nick: @userId
          room_name: args.room_name
          foreground_uuid: args.uuid
        , $set:
          foreground: args.foreground or false
      return

    get: (type, id) ->
      check @userId, NonEmptyString
      check type, NonEmptyString
      check id, NonEmptyString
      return collection(type).findOne(id)

    getByName: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        optional_type: Match.Optional(NonEmptyString)
      for type in ['rounds','puzzles']
        continue if args.optional_type and args.optional_type isnt type
        o = collection(type).findOne canon: canonical(args.name)
        return {type:type,object:o} if o
      unless args.optional_type and args.optional_type isnt 'nicks'
        o = Meteor.users.findOne canonical args.name
        return {type: 'nicks', object: o} if o

    setField: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidType
        object: IdOrObject
        fields: Object
      id = args.object._id or args.object
      now = UTCNow()
      # disallow modifications to the following fields; use other APIs for these
      for f in ['name','canon','created','created_by','solved','solved_by',
               'tags','puzzles','incorrectAnswers', 'feedsInto',
               'located','located_at',
               'priv_located','priv_located_at','priv_located_order']
        delete args.fields[f]
      args.fields.touched = now
      args.fields.touched_by = @userId
      collection(args.type).update id, $set: args.fields
      return true

    setTag: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        type: ValidType
        object: IdOrObject
        value: String
      # bail to setAnswer/deleteAnswer if this is the 'answer' tag.
      if canonical(args.name) is 'answer'
        return Meteor.call (if args.value then "setAnswer" else "deleteAnswer"),
          type: args.type
          target: args.object
          answer: args.value
      if canonical(args.name) is 'link'
        args.fields = { link: args.value }
        return Meteor.call 'setField', args
      args.now = UTCNow() # don't let caller lie about the time
      updateDoc = $set:
        touched: args.now
        touched_by: @userId
      id = args.object._id or args.object
      setTagInternal updateDoc, {args..., who: @userId}
      0 < collection(args.type).update id, updateDoc

    deleteTag: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        type: ValidType
        object: IdOrObject
      id = args.object._id or args.object
      # bail to deleteAnswer if this is the 'answer' tag.
      if canonical(args.name) is 'answer'
        return Meteor.call "deleteAnswer",
          type: args.type
          target: args.object
      if canonical(args.name) is 'link'
        args.fields = { link: null }
        return Meteor.call 'setField', args
      args.now = UTCNow() # don't let caller lie about the time
      updateDoc = $set:
        touched: args.now
        touched_by: @userId
      deleteTagInternal updateDoc, args.name
      0 < collection(args.type).update id, updateDoc

    summon: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        object: IdOrObject
        how: Match.Optional(NonEmptyString)
      id = args.object._id or args.object
      obj = Puzzles.findOne id
      if not obj?
        return "Couldn't find puzzle #{id}"
      if obj.solved
        return "puzzle #{obj.name} is already answered"
      wasStuck = isStuck obj
      rawhow = args.how or 'Stuck'
      how = if rawhow.toLowerCase().startsWith('stuck') then rawhow else "Stuck: #{rawhow}"
      Meteor.call 'setTag',
        object: id
        type: 'puzzles'
        name: 'Stuckness'
        value: how
        now: UTCNow()
      if isStuck obj
        return
      oplog "Help requested for", 'puzzles', id, @userId, 'stuck'
      body = "has requested help: #{rawhow}"
      Meteor.call 'newMessage',
        action: true
        body: body
        room_name: "puzzles/#{id}"
      objUrl = # see Router.urlFor
        Meteor._relativeToSiteRootUrl "/puzzles/#{id}"
      body = "has requested help: #{UI._escape rawhow} (puzzle <a class=\"puzzles-link\" href=\"#{objUrl}\">#{UI._escape obj.name}</a>)"
      Meteor.call 'newMessage',
        action: true
        bodyIsHtml: true
        body: body
      return

    unsummon: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        object: IdOrObject
      id = args.object._id or args.object
      obj = Puzzles.findOne id
      if not obj?
        return "Couldn't find puzzle #{id}"
      if not (isStuck obj)
        return "puzzle #{obj.name} isn't stuck"
      oplog "Help request cancelled for", 'puzzles', id, @userId
      sticker = obj.tags.stuckness?.touched_by
      Meteor.call 'deleteTag',
        object: id
        type: 'puzzles'
        name: 'Stuckness'
        now: UTCNow()
      body = "has arrived to help"
      if @userId is sticker
        body = "no longer needs help getting unstuck"
      Meteor.call 'newMessage',
        action: true
        body: body
        room_name: "puzzles/#{id}"
      body = "#{body} in puzzle #{obj.name}"
      Meteor.call 'newMessage',
        action: true
        body: body
      return

    getRoundForPuzzle: (puzzle) ->
      check @userId, NonEmptyString
      check puzzle, IdOrObject
      id = puzzle._id or puzzle
      check id, NonEmptyString
      return Rounds.findOne(puzzles: id)

    moveWithinMeta: (id, parentId, args) ->
      check @userId, NonEmptyString
      args.who = @userId
      moveWithinParent id, 'puzzles', parentId, args

    moveWithinRound: (id, parentId, args) ->
      check @userId, NonEmptyString
      args.who = @userId
      moveWithinParent id, 'rounds', parentId, args

    moveRound: (id, dir) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      round = Rounds.findOne(id)
      order = 1
      op = '$gt'
      if dir < 0
        order = -1
        op = '$lt'
      query = {}
      query[op] = round.sort_key
      last = Rounds.findOne {sort_key: query}, sort: {sort_key: order}
      return unless last?
      Rounds.update id, $set: sort_key: last.sort_key
      Rounds.update last._id, $set: sort_key: round.sort_key
      return

    setAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        target: IdOrObject
        answer: NonEmptyString
        backsolve: Match.Optional(Boolean)
        provided: Match.Optional(Boolean)
      id = args.target._id or args.target

      # Only perform the update and oplog if the answer is changing
      puzzle = Puzzles.findOne(id)
      oldAnswer = puzzle?.tags.answer?.value
      if oldAnswer is args.answer
        return false

      now = UTCNow()
      updateDoc = $set:
        solved: now
        solved_by: @userId
        touched: now
        touched_by: @userId
      setTagInternal updateDoc,
        name: 'Answer'
        value: args.answer
        who: @userId
        now: now
      deleteTagInternal updateDoc, 'status'
      if args.backsolve
        setTagInternal updateDoc,
          name: 'Backsolve'
          value: 'yes'
          who: @userId
          now: now
      else
        deleteTagInternal updateDoc, 'Backsolve'
      if args.provided
        setTagInternal updateDoc,
          name: 'Provided'
          value: 'yes'
          who: @userId
          now: now
      else
        deleteTagInternal updateDoc, 'Provided'
      updated = Puzzles.update
        _id: id
        'tags.answer.value': $ne: args.answer
      , updateDoc
      share.discordBot.deleteVoiceChannelWithTimeout(puzzle.name)
      return false if updated is 0
      oplog "Found an answer (#{args.answer.toUpperCase()}) to", 'puzzles', id, @userId, 'answers'
      return true

    addIncorrectAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        target: IdOrObject
        answer: NonEmptyString
        backsolve: Match.Optional(Boolean)
        provided: Match.Optional(Boolean)
      id = args.target._id or args.target
      now = UTCNow()

      target = Puzzles.findOne(id)
      throw new Meteor.Error(400, "bad target") unless target
      Puzzles.update id, $push:
        incorrectAnswer:
          answer: args.answer
          timestamp: UTCNow()
          who: @userId
          backsolve: !!args.backsolve
          provided: !!args.provided

      oplog "reports incorrect answer #{args.answer} for", 'puzzles', id, @userId, \
          'nonanswers'
      return true

    deleteAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        target: IdOrObject
      id = args.target._id or args.target
      now = UTCNow()
      updateDoc = $set:
        solved: null
        solved_by: null
        touched: now
        touched_by: @userId
      deleteTagInternal updateDoc, 'answer'
      deleteTagInternal updateDoc, 'backsolve'
      deleteTagInternal updateDoc, 'provided'
      Puzzles.update id, updateDoc
      puzzle = Puzzles.findOne(id)
      share.discordBot.newVoiceChannel((Meteor.call 'getRoundForPuzzle', id).name, puzzle.name)
      oplog "Deleted answer for", 'puzzles', id, @userId
      return true

    favorite: (puzzle) ->
      check @userId, NonEmptyString
      check puzzle, NonEmptyString
      num = Puzzles.update puzzle, $set:
        "favorites.#{@userId}": true
      num > 0

    unfavorite: (puzzle) ->
      check @userId, NonEmptyString
      check puzzle, NonEmptyString
      num = Puzzles.update puzzle, $unset:
        "favorites.#{@userId}": ''
      num > 0

    addMechanic: (puzzle, mechanic) ->
      check @userId, NonEmptyString
      check puzzle, NonEmptyString
      check mechanic, IsMechanic
      if mechanic == 'all hands (swarm)'
        puzzleDbObj = Puzzles.findOne puzzle
        roundName = (Meteor.call 'getRoundForPuzzle', puzzle).name or 'No round'
        share.discordBot.swarmNotify({id: puzzle, name: puzzleDbObj.name, mechanics: puzzleDbObj.mechanics, round: roundName})
      num = Puzzles.update puzzle,
        $addToSet: mechanics: mechanic
        $set:
          touched: UTCNow()
          touched_by: @userId
      throw new Meteor.Error(404, "bad puzzle") unless num > 0

    removeMechanic: (puzzle, mechanic) ->
      check @userId, NonEmptyString
      check puzzle, NonEmptyString
      check mechanic, IsMechanic
      if mechanic == 'all hands (swarm)'
        share.discordBot.swarmStop(puzzle)
      num = Puzzles.update puzzle,
        $pull: mechanics: mechanic
        $set:
          touched: UTCNow()
          touched_by: @userId
      throw new Meteor.Error(404, "bad puzzle") unless num > 0

    # if a round/puzzle folder gets accidentally deleted, this can be used to
    # manually re-create it.
    fixSheet: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidType
        object: IdOrObject
        name: NonEmptyString
      id = args.object._id or args.object
      newSheet id, args.name

    shareFolder: (email) ->
      check @userId, NonEmptyString
      check email, NonEmptyString
      # check @userId, NonEmptyString
      # check email, NonEmptyString
      share.drive.shareFolder email

    whiteboardSubmit: (content) ->
      if Meteor.isServer
        whiteboardColl = collection('whiteboard')
        whiteboard = whiteboardColl.findOne({}, { sort: { timestamp: -1 } }) or whiteboardColl.insert {}
        whiteboardColl.update {_id: whiteboard._id}, $set:
          content: content # potential danger zone?
          timestamp: Date.now()
)()

UTCNow = -> Date.now()

# exports
share.model =
  # constants
  PRESENCE_KEEPALIVE_MINUTES: PRESENCE_KEEPALIVE_MINUTES
  NOT_A_TIMESTAMP: NOT_A_TIMESTAMP
  # collection types
  Names: Names
  LastAnswer: LastAnswer
  Rounds: Rounds
  Puzzles: Puzzles
  Messages: Messages
  LastRead: LastRead
  Presence: Presence
  Whiteboard: Whiteboard
  # helper methods
  collection: collection
  pretty_collection: pretty_collection
  getTag: getTag
  isStuck: isStuck
  canonical: canonical
  drive_id_to_link: drive_id_to_link
  spread_id_to_link: spread_id_to_link
  UTCNow: UTCNow