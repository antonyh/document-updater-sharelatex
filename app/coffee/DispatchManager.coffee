Settings = require('settings-sharelatex')
logger = require('logger-sharelatex')
Keys = require('./UpdateKeys')
redis = require("redis-sharelatex")

UpdateManager = require('./UpdateManager')
Metrics = require('./Metrics')
RateLimitManager = require('./RateLimitManager')

module.exports = DispatchManager =
	createDispatcher: (RateLimiter) ->
		client = redis.createClient(Settings.redis.realtime)
		worker = {
			client: client
			_waitForUpdateThenDispatchWorker: (callback = (error) ->) ->
				timer = new Metrics.Timer "worker.waiting"
				worker.client.blpop "pending-updates-list", 0, (error, result) ->
					timer.done()
					return callback(error) if error?
					return callback() if !result?
					[list_name, doc_key] = result
					[project_id, doc_id] = Keys.splitProjectIdAndDocId(doc_key)
					# Dispatch this in the background
					backgroundTask = (cb) ->
						UpdateManager.processOutstandingUpdatesWithLock project_id, doc_id, (error) ->
							logger.error err: error, project_id: project_id, doc_id: doc_id, "error processing update" if error?
							cb()
					RateLimiter.run backgroundTask, callback
						
			run: () ->
				return if Settings.shuttingDown
				worker._waitForUpdateThenDispatchWorker (error) =>
					if error?
						logger.error err: error, "Error in worker process"
						throw error
					else
						worker.run()
		}
		
		return worker
		
	createAndStartDispatchers: (number) ->
		RateLimiter = new RateLimitManager(number)
		for i in [1..number]
			worker = DispatchManager.createDispatcher(RateLimiter)
			worker.run()
