express = require('express')
http = require("http")
Settings = require('settings-sharelatex')
logger = require('logger-sharelatex')
logger.initialize("documentupdater")
if Settings.sentry?.dsn?
	logger.initializeErrorReporting(Settings.sentry.dsn)

RedisManager = require('./app/js/RedisManager')
DispatchManager = require('./app/js/DispatchManager')
Errors = require "./app/js/Errors"
HttpController = require "./app/js/HttpController"

Path = require "path"
Metrics = require "metrics-sharelatex"
Metrics.initialize("doc-updater")
Metrics.mongodb.monitor(Path.resolve(__dirname + "/node_modules/mongojs/node_modules/mongodb"), logger)
Metrics.event_loop.monitor(logger, 100)

app = express()
app.configure ->
	app.use(Metrics.http.monitor(logger));
	app.use express.bodyParser()
	app.use app.router

DispatchManager.createAndStartDispatchers(Settings.dispatcherCount || 10)

app.param 'project_id', (req, res, next, project_id) ->
	if project_id?.match /^[0-9a-f]{24}$/
		next()
	else
		next new Error("invalid project id")

app.param 'doc_id', (req, res, next, doc_id) ->
	if doc_id?.match /^[0-9a-f]{24}$/
		next()
	else
		next new Error("invalid doc id")

app.get    '/project/:project_id/doc/:doc_id',                          HttpController.getDoc
app.post   '/project/:project_id/doc/:doc_id',                          HttpController.setDoc
app.post   '/project/:project_id/doc/:doc_id/flush',                    HttpController.flushDocIfLoaded
app.delete '/project/:project_id/doc/:doc_id',                          HttpController.flushAndDeleteDoc
app.delete '/project/:project_id',                                      HttpController.deleteProject
app.post   '/project/:project_id/flush',                                HttpController.flushProject
app.post   '/project/:project_id/doc/:doc_id/change/:change_id/accept', HttpController.acceptChanges
app.post   '/project/:project_id/doc/:doc_id/change/accept',            HttpController.acceptChanges
app.del    '/project/:project_id/doc/:doc_id/comment/:comment_id',      HttpController.deleteComment

app.get '/total', (req, res)->
	timer = new Metrics.Timer("http.allDocList")	
	RedisManager.getCountOfDocsInMemory (err, count)->
		timer.done()
		res.send {total:count}
	
app.get '/status', (req, res)->
	if Settings.shuttingDown
		res.send 503 # Service unavailable
	else
		res.send('document updater is alive')

webRedisClient = require("redis-sharelatex").createClient(Settings.redis.realtime)
app.get "/health_check/redis", (req, res, next) ->
	webRedisClient.healthCheck (error) ->
		if error?
			logger.err {err: error}, "failed redis health check"
			res.send 500
		else
			res.send 200

docUpdaterRedisClient = require("redis-sharelatex").createClient(Settings.redis.documentupdater)
app.get "/health_check/redis_cluster", (req, res, next) ->
	docUpdaterRedisClient.healthCheck (error) ->
		if error?
			logger.err {err: error}, "failed redis cluster health check"
			res.send 500
		else
			res.send 200

app.use (error, req, res, next) ->
	if error instanceof Errors.NotFoundError
		res.send 404
	else if error instanceof Errors.OpRangeNotAvailableError
		res.send 422 # Unprocessable Entity
	else
		logger.error err: error, req: req, "request errored"
		res.send(500, "Oops, something went wrong")

shutdownCleanly = (signal) ->
	return () ->
		logger.log signal: signal, "received interrupt, cleaning up"
		Settings.shuttingDown = true
		setTimeout () ->
			logger.log signal: signal, "shutting down"
			process.exit()
		, 10000

port = Settings.internal?.documentupdater?.port or Settings.apis?.documentupdater?.port or 3003
host = Settings.internal.documentupdater.host or "localhost"
app.listen port, host, ->
	logger.info "Document-updater starting up, listening on #{host}:#{port}"

for signal in ['SIGINT', 'SIGHUP', 'SIGQUIT', 'SIGUSR1', 'SIGUSR2', 'SIGTERM', 'SIGABRT']
	process.on signal, shutdownCleanly(signal)
