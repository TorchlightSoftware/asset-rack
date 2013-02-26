{gzip} = require 'zlib'
async = require 'async'
pkgcloud = require 'pkgcloud'
{EventEmitter} = require 'events'

{BufferStream, extend} = require('./util')
ClientRack = require('./client').ClientRack
AmdRack = require('./modules/amd').AmdRack

class exports.Rack extends EventEmitter
    constructor: (assets, options) ->
        super()
        options ?= {}
        @maxAge = options.maxAge
        @allowNoHashCache = options.allowNoHashCache
        @on 'complete', =>
            @completed = true
        @on 'newListener', (event, listener) =>
            if event is 'complete' and @completed is true
                listener()
        @on 'error', (error) =>
            throw error if @listeners('error').length is 1
        for asset in assets
            asset.rack = this
        @assets = []
        async.forEach assets, (asset, next) =>
            asset.on 'error', (error) =>
                next error
            asset.on 'complete', =>
                if asset.contents?
                    @assets.push asset
                if asset.assets?
                    @assets.push asset.assets...
                next()
            asset.rack = this
            asset.emit 'start'
        , (error) =>
            return @emit 'error', error if error?
            @emit 'complete'

    ready: (task) ->
        if @completed
            task()
        else @on 'complete', task

    createClientRack: ->
        clientRack =  new ClientRack
        clientRack.rack = this
        clientRack.emit 'start'
        clientRack

    addClientRack: (next) ->
        clientRack = @createClientRack()
        clientRack.on 'complete', =>
            @assets.push clientRack
            next null, clientRack

    createAmdRack: (options) ->
        amdRack = new AmdRack options
        amdRack.rack = this
        amdRack.emit 'start'
        amdRack

    addAmdRack: (options, next) ->
        amdRack = @createAmdRack(options)
        amdRack.on 'complete', =>
            @assets.push amdRack
            next null, amdRack

    handle: (request, response, next) ->
        response.locals assets: this if response.locals # only present with Express
        handle = =>
            for asset in @assets
                check = asset.checkUrl request.url
                return asset.respond request, response if check
            next()
        if @completed
            handle()
        else @on 'complete', handle

    deploy: (options, next) ->
        options.keyId = options.accessKey
        options.key = options.secretKey
        @ready =>
            client = pkgcloud.storage.createClient options

            assets = @assets
            # Big time hack for rackspace, first asset doesn't upload, very strange.
            # Might be bug with pkgcloud.  This hack just uploads the first file again
            # at the end.
            assets = @assets.concat @assets[0] if options.provider is 'rackspace'
            uploadAsset = (asset, next) =>
                stream = new BufferStream asset.contents
                url = asset.specificUrl.slice 1, asset.specificUrl.length
                headers = {}
                for key, value of asset.headers
                    headers[key] = value

                headers['x-amz-acl'] = 'public-read' if options.provider is 'amazon'
                headers['Content-Encoding'] = 'gzip' if asset.compress

                upload = (stream) ->
                  clientOptions =
                      container: options.container
                      remote: url
                      headers: headers
                      stream: stream

                  client.upload clientOptions, (error) ->
                      return next error if error?
                      next()

                if asset.compress
                  gzip stream.data, (err, data) ->
                    stream.data = data
                    upload stream
                else
                  upload stream

            async.forEachSeries assets, uploadAsset, (error) ->
                if next?
                  return next error
                else if error?
                  throw error

    tag: (url) ->
        for asset in @assets
            return asset.tag() if asset.url is url
        return undefined

    url: (url) ->
        for asset in @assets
            return asset.specificUrl if url is asset.url
        return undefined

    @extend: extend
