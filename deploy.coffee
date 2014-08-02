#!/usr/bin/env coffee

AWS        = require 'aws-sdk'
AWS_DEPLOY_KEY    = require("fs").readFileSync("#{__dirname}/install/keys/aws/koding-prod-deployment.pem")
AWS.config.region = 'us-east-1'
AWS.config.update accessKeyId: 'AKIAI7RHT42HWAA652LA', secretAccessKey: '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'

argv       = require('minimist')(process.argv.slice(2))
eden       = require 'node-eden'
log        = console.log
timethat   = require 'timethat'
Connection = require "ssh2"
fs         = require 'fs'
semver     = require 'semver'
{exec}     = require 'child_process'
request    = require 'request'
ec2        = new AWS.EC2()
elb        = new AWS.ELB()


class Release

  works = ->
    elb.deregisterInstancesFromLoadBalancer
      Instances        : [{ InstanceId: 'i-dd310cf7' }]
      LoadBalancerName : "koding-prod-deployment"
    ,(err,res) ->
      log err,res


    elb.registerInstancesWithLoadBalancer
      Instances        : [{ InstanceId: 'i-dd310cf7' }]
      LoadBalancerName : "koding-prod-deployment"
    ,(err,res) ->
      log err,res


    elb.describeInstanceHealth
      Instances        : [{ InstanceId: 'i-dd310cf7' }]
      LoadBalancerName : "koding-prod-deployment"
    ,(err,res)->
      log err,res

  @fetchLoadBalancerInstances = (LoadBalancerName,callback)->
    elb.describeLoadBalancers LoadBalancerNames : [LoadBalancerName],(err,res)->
      log res.LoadBalancerDescriptions[0].Instances

    ec2.describeInstances {},(err,res)->

  fetchInstancesWithPrefix = (prefix,callback)->

    pickValueOf= (key,array) -> return val.Value if val.Key is key for val in array
    instances = []
    ec2.describeInstances {},(err,res)->
      # log err,res
      for r in res.Reservations
        a = InstanceId: r.Instances[0].InstanceId, Name: pickValueOf "Name",r.Instances[0].Tags
        b = InstanceId: r.Instances[0].InstanceId
        instances.push b if a.Name.indexOf(prefix) > -1
      # log instances
      callback null,instances

  @registerInstancesWithPrefix = (prefix, callback)->
    fetchInstancesWithPrefix prefix, (err,instances)->
      # log instances
      elb.registerInstancesWithLoadBalancer
        Instances        : instances
        LoadBalancerName : "koding-prod-deployment"
      ,callback

  @deregisterInstancesWithPrefix = (prefix, callback)->
    fetchInstancesWithPrefix prefix, (err,instances)->
      log instances
      elb.deregisterInstancesFromLoadBalancer
        Instances        : instances
        LoadBalancerName : "koding-prod-deployment"
      ,callback



class Deploy

  @connect = (options,callback) ->
    {IP,username,password,retries,timeout} = options

    options.retry = yes unless options.retrying

    conn = new Connection()

    listen = (prefix, stream, callback)->
      _log = (data) -> log ("#{prefix} #{data}").replace("\n","") if data or data is not ""
      stream.on          "data", _log
      stream.stderr.on   "data", _log
      stream.on "close", callback
      # stream.on "exit", (code, signal) -> log "[#{prefix}] did exit."

    sftpCopy = (options, callback)->
      copyCount = 1
      results = []
      options.conn.sftp (err, sftp) ->
        for file,nr in options.files
          do (file)->
            sftp.fastPut file.src,file.trg,(err,res)->
              if err
                log "couldn't copy:",file
                throw err
              log file.src+" is copied to "+file.trg
              if copyCount is options.files.length then callback null,"done"
              copyCount++

    conn.connect
      host         : IP
      port         : 22
      username     : username
      privateKey   : AWS_DEPLOY_KEY
      readyTimeout : timeout


    conn.on "ready", ->
      conn.listen   = listen
      conn.sftpCopy = sftpCopy
      callback null,conn

    conn.on "error", (err) -> retry()


    retry = ->
      if options.retries > 1
        options.retries = options.retries-1
        log "connecting to instance.. attempts left:#{options.retries}"
        setTimeout (-> Deploy.connect options, callback),timeout
      else
        log "not retrying anymore.", options.retries
        callback "error connecting."

  @createLoadBalancer = (options,callback)->
    elb.createLoadBalancer
      LoadBalancerName : options.name
      Listeners : [
        InstancePort     : 80
        LoadBalancerPort : 80
        Protocol         : "http"
        InstanceProtocol : "http"
      ]
      Subnets        : ["subnet-b47692ed"]
      SecurityGroups : ["sg-64126d01"]
    ,callback

  @createInstance = (options={}, callback) ->

    # Creates a new instance and returns a live connection.
    buildNumber  = options.buildNumber  or 1113
    instanceName = options.instanceName or "prod-#{buildNumber}-#{eden.eve().toLowerCase()}"

    params = options.params or
      ImageId       : "ami-a6926dce" # Amazon ubuntu 14.04 "ami-1624987f" # Amazon Linux AMI x86_64 EBS
      InstanceType  : "t2.micro"
      MinCount      : 1
      MaxCount      : 1
      SubnetId      : "subnet-b47692ed"
      KeyName       : "koding-prod-deployment"

    iamcalledonce = 0

    start = new Date()

    ec2.runInstances params, (err, data) ->
      iamcalledonce++
      if iamcalledonce > 1 then return log "i am called #{iamcalledonce} times"
      if err
        # log "\n\nCould not create instance ---->", err
        log """code:#{err.code},name:#{err.name},code:#{err.statusCode},#{err.retryable}
         ---
         [ERROR] #{err.message}
        \n\n
        """
        return
      else
        instanceId = data.Instances[0].InstanceId
        log "Created instance", instanceId

        # Add tags to the instance
        params =
          Resources: [instanceId]
          Tags: [
            Key   : "Name"
            Value : instanceName
          ]

        ec2.createTags params, (err) ->
          log "Box tagged with #{instanceName}", (if err then "failure" else "success")

          params =
            InstanceIds : [instanceId]

          states =
            initialState  : null
            instanceState : null
            reachability  : null

          timer = setInterval ->

            unless states.initialState is "running" or states.instanceState is "running"

              ec2.describeInstanceStatus params,(err,data)->
                if err then log err
                else
                  states.instanceState = data?.InstanceStatuses?[0]?.InstanceState?.Name
                  states.reachability  = data?.InstanceStatuses?[0]?.InstanceStatus?.Details?[0]?.Status

              ec2.describeInstances params,(err,data)->
                if err then log err
                else
                  states.initialState = data?.Reservations?[0]?.Instances?[0]?.State?.Name
                  states.final        = data?.Reservations?[0]?.Instances?[0]
            else
              log "instance is now running with IP:", IP = states.final.PublicIpAddress
              clearInterval timer

              Deploy.connect IP: IP, username: "ubuntu", retries: 30, timeout: 5000, (err,conn)->
                unless err
                  log "creating #{instanceName} took "+ timethat.calc start,new Date()
                  conn.exec "uptime;",(err, stream)->

                    return log err  if err
                    conn.listen "-->", stream,->
                      log "connection established... preparing the box."
                      conn.final = states.final

                      res =
                        conn : conn
                        instanceData : states.final
                        instanceName : instanceName
                        buildOptions : options

                      callback null, res
                else
                  log "ignoring err callback", err

          ,5000

  @deployAndConfigure = (options,callback)->


    Deploy.createInstance options,(err,result) ->
      deployStart = new Date()
      {conn} = result

      conn.exec options.buildScript, (err, stream) ->
        throw err if err
        conn.listen "[configuring #{result.instanceName}]", stream,->
          throw err if err
          # delete result.conn
          # log result.instanceData
          log "Deployment of #{result.instanceName} took: "+timethat.calc deployStart,new Date()
          conn.end()
          callback null, result

  @deployTest = (options,callback)->

    i = 0
    result = []
    options.forEach (option) ->

      {target, url, expectString} = option
      __start = new Date()
      request "#{url}",(err,res,body)->
        i++
        __end = timethat.calc __start,new Date()

        if not err and body.indexOf expectString > -1
          result.push "[ TEST  PASSED #{__end} ] #{target}"
        else result.push "[ TEST #FAILED #{__end} ] #{target}"

        callback null, result if i is options.length

  @getCurrentVersion = (options,callback=->)->
    exec "git fetch --tags && git tag",(a,b,c)->

      tags = b.split('\n')
      # remove invalid versions, otherwise semver throws an error
      tags[key] = "v0.0.0" for version,key in tags when not semver.valid version
      tags    = tags.sort semver.compare
      version = tags.pop()



      callback null,version

  @getNextVersion = (options, callback)->
    type = options.versiontype or "patch"
    Deploy.getCurrentVersion {},(err,version)->
      log "current version is #{version}"
      callback null, "v"+semver.inc(version,type)

release = (key)->
  Release.registerInstancesWithPrefix key,(err,res)->
    log res
    log ""
    log ""
    log "------------------------------------------------------------------------------"
    log "#{key} is now deployed and live with bazillion instances."
    log "------------------------------------------------------------------------------"

rollback = (key)->
  Release.deregisterInstancesWithPrefix key,(err,res)->
    log res
    log ""
    log ""
    log "------------------------------------------------------------------------------"
    log "#{key} is now rolled back. All instances are taken out of rotation."
    log "------------------------------------------------------------------------------"


if argv.release
  release argv.release

if argv.rollback
  rollback argv.rollback

if argv.deploy
  d = new Date()
  log "fetching latest version tag. please wait... "

  Deploy.getNextVersion {},(err,version)->


    options =
      boxes       : argv.boxes          or 5
      boxtype     : argv.boxtype        or "t2.medium"
      versiontype : argv.versiontype    or "patch"  # available options major, premajor, minor, preminor, patch, prepatch, or prerelease
      target      : argv.target         or "singlebox" # prod | staging | sandbox
      version     : argv.version        or version

    options.hostname     = "#{options.target}--#{options.version.replace(/\./g,'-')}"
    options.instanceName = "#{options.hostname}--#{eden.eve().toLowerCase()}"
    KONFIG = require("./config/main.prod.coffee")
      hostname : options.instanceName
      tag      : options.tag

    #create the new tag
    log "tagging version #{options.version}"
    exec "git tag -a '#{options.version}' -m '#{KONFIG.machineSettings}' && git push --tags",(err,stdout,stderr)->

      if options.target is "singlebox"

        options =
          params :
            ImageId       : "ami-864d84ee" # Amazon ubuntu 14.04 "ami-1624987f" # Amazon Linux AMI x86_64 EBS
            InstanceType  : options.boxtype
            MinCount      : 1
            MaxCount      : 1
            SubnetId      : "subnet-b47692ed"
            KeyName       : "koding-prod-deployment"
            UserData      : new Buffer(KONFIG.runFile).toString('base64')
          instanceName    : options.instanceName
          configName      : "singlebox"
          environment     : "singlebox"
          tag             : options.version
          buildScript     : "tail -fq /var/log/syslog"



        Deploy.deployAndConfigure options,(err,res)->
          IP = res.instanceData.PublicIpAddress
          Deploy.deployTest [
              {url : "http://#{IP}:3000/"          , target: "webserver"          , expectString: "UA-6520910-8"}
              {url : "http://#{IP}:3030/xhr"       , target: "socialworker"       , expectString: "Cannot GET"}
              {url : "http://#{IP}:8008/subscribe" , target: "broker"             , expectString: "Cannot GET"}
              {url : "http://#{IP}:5500/kite"      , target: "kloud"              , expectString: "Welcome"}
              {url : "http://#{IP}/"               , target: "webserver-nginx"    , expectString: "UA-6520910-8"}
              {url : "http://#{IP}/xhr"            , target: "socialworker-nginx" , expectString: "Cannot GET"}
              {url : "http://#{IP}/subscribe"      , target: "broker-nginx"       , expectString: "Cannot GET"}
              {url : "http://#{IP}/kloud/kite"     , target: "kloud-nginx"        , expectString: "Welcome"}
            ]
          ,(err,test_res)->
            log val for val in test_res



            log "#{res.instanceName} is ready."
            log "Box is ready at mosh root@#{res.instanceData.PublicIpAddress}"

# KONFIG = require("./config/main.prod.coffee")
#   hostname : "foo"
#   tag      : "options.tag"


# fs.writeFileSync "./foo.sh",KONFIG.runFile
# fs.writeFileSync "./foo.sh64",fs.readFileSync("./foo.sh").toString('base64')




# ze = ec2.createImage

#   InstanceId: 'i-c7fdeaed'
#   Name: 'test1'+Date.now()
#   # BlockDeviceMappings: [
#   #   {
#   #     # DeviceName: 'testdevicename',
#   #     Ebs:
#   #       DeleteOnTermination: yes
#   #       # Encrypted: no
#   #       # Iops: 100 # Required when the volume type is io1; not used with standard or gp2 volumes.
#   #       # SnapshotId: 'snap-koding-v1.5.5'
#   #       VolumeSize: 8,
#   #       VolumeType: 'standard' # | io1 | gp2'

#   #     # NoDevice: 'STRING_VALUE',
#   #     # VirtualName: 'STRING_VALUE'
#   #   }
#   # ]
#   Description: 'testing image'
#   # DryRun: true || false,
#   NoReboot: false
# ,(err,callback)->
#   log arguments
#   start = new Date()

#   ze.on("success"  , (response)      -> console.log "Success!", timethat.calc start,new Date()
#   ).on("error"     , (response)      -> console.log "Error!"
#   ).on("complete"  , (response)      -> console.log "Always!", timethat.calc start,new Date()
#   ).send()
