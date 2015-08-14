actions              = require '../../actions/actiontypes'
{ expect }           = require 'chai'
Reactor              = require 'app/flux/reactor'
UsersStore           = require '../../stores/usersstore'
generateDummyAccount = require 'app/util/generateDummyAccount'

describe 'UsersStore', ->

  beforeEach ->
    @reactor = new Reactor
    @reactor.registerStores [UsersStore]

  describe '#handleLoadSuccess', ->

    it 'loads user', ->

      account = generateDummyAccount '123', 'foouser'

      @reactor.dispatch actions.LOAD_USER_SUCCESS, { id: '123', account }

      storeState = @reactor.evaluateToJS [UsersStore.getterPath]

      expect(storeState['123']).to.eql account


  describe '#handleLoadListSuccess', ->

    it 'loads user list', ->

      account1 = generateDummyAccount '123', 'qwertyuser'
      account2 = generateDummyAccount '456', 'testuser'
      users    = [ account1, account2 ]

      @reactor.dispatch actions.SEARCH_USERS_SUCCESS, { users }

      storeState = @reactor.evaluateToJS [UsersStore.getterPath]

      expect(storeState['123']).to.eql account1
      expect(storeState['456']).to.eql account2
