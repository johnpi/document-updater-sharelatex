sinon = require('sinon')
chai = require('chai')
should = chai.should()
modulePath = "../../../../app/js/RealTimeRedisManager.js"
SandboxedModule = require('sandboxed-module')
Errors = require "../../../../app/js/Errors"

describe "RealTimeRedisManager", ->
	beforeEach ->
		@rclient =
			auth: () ->
			exec: sinon.stub()
		@rclient.multi = () => @rclient
		@RealTimeRedisManager = SandboxedModule.require modulePath, requires:
			"redis-sharelatex": createClient: () => @rclient
			"settings-sharelatex":
				redis:
					realtime: @settings =
						key_schema:
							pendingUpdates: ({doc_id}) -> "PendingUpdates:#{doc_id}"
			"logger-sharelatex": { log: () -> }
		@doc_id = "doc-id-123"
		@project_id = "project-id-123"
		@callback = sinon.stub()
	
	describe "getPendingUpdatesForDoc", ->
		beforeEach ->
			@rclient.lrange = sinon.stub()
			@rclient.del = sinon.stub()

		describe "successfully", ->
			beforeEach ->
				@updates = [
					{ op: [{ i: "foo", p: 4 }] }
					{ op: [{ i: "foo", p: 4 }] }
				]
				@jsonUpdates = @updates.map (update) -> JSON.stringify update
				@rclient.exec = sinon.stub().callsArgWith(0, null, [@jsonUpdates])
				@RealTimeRedisManager.getPendingUpdatesForDoc @doc_id, @callback
			
			it "should get the pending updates", ->
				@rclient.lrange
					.calledWith("PendingUpdates:#{@doc_id}", 0, -1)
					.should.equal true

			it "should delete the pending updates", ->
				@rclient.del
					.calledWith("PendingUpdates:#{@doc_id}")
					.should.equal true

			it "should call the callback with the updates", ->
				@callback.calledWith(null, @updates).should.equal true

		describe "when the JSON doesn't parse", ->
			beforeEach ->
				@jsonUpdates = [
					JSON.stringify { op: [{ i: "foo", p: 4 }] }
					"broken json"
				]
				@rclient.exec = sinon.stub().callsArgWith(0, null, [@jsonUpdates])
				@RealTimeRedisManager.getPendingUpdatesForDoc @doc_id, @callback

			it "should return an error to the callback", ->
				@callback.calledWith(new Error("JSON parse error")).should.equal true


	describe "getUpdatesLength", ->
		beforeEach ->
			@rclient.llen = sinon.stub().yields(null, @length = 3)
			@RealTimeRedisManager.getUpdatesLength @doc_id, @callback
		
		it "should look up the length", ->
			@rclient.llen.calledWith("PendingUpdates:#{@doc_id}").should.equal true
		
		it "should return the length", ->
			@callback.calledWith(null, @length).should.equal true
