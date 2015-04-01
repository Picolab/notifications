ruleset notifications {
  meta {
    name "Notification Service"
    description <<
This app responds to notification events.  Unlike the Simple Notification Service (a16x128)
on which it is modeled, this service is designed to work in the CloudOS.

Copyright 2015 Pico Labs LLC, All Rights Reserved
>>

    author "Phil Windley"
    logging off

    sharing on
    provides ownerChannels, timelineItems, rawTimeline

    use module b16x24 alias pico_keys
                        
    use module a169x699 alias twilio with twiliokeys = keys:twilio()
          
    use module a16x129 version "dev" alias sendgrid with
          api_user = keys:sendgrid("api_user") and 
          api_key = keys:sendgrid("api_key") and
          from = "noreply@joinfuse.com" and
          fromname = "Fuse-NoReply"
                      
    use module a169x676 version "prod" alias pds
    use module a169x625 alias CloudOS

  }

  dispatch {
  }

  global {

    // configuration variables
    level_names = {
      "sms": {
        "name": "SMS",
        "description": "Send an SMS to the number in the user profile",
        "display" : true
      }, 
      "email": {
        "name": "Email",
        "description": "Send an email to the address in the user profile",
        "display" : true
      }, 
      "logonly": {
        "name": "Log Only",
        "description": "Add the notification item to the timeline",
        "display" : false
      }, 
      "nothing": {
        "name": "Do Nothing",
        "description": "Don't do anything with this notification",
        "display" : true
      }
    };

    // find out about user from profile
    name  = function(){
      pds:get_me('myProfileName');
    };
    email_addr = function(){
      pds:get_me('myProfileEmail')
    };
    phone_num = function(){
      pds:get_me('myProfilePhone')
    };
    notification_pref = function() {
      // one of "info", "alert", or "emergency"
      pds:get_me("notificationPreferences") || "alert"
    };

    system_number = function() {
     "801-200-3415"
    };

    // --------------------------------------------
    ownerChannels = function() {
        all_subs = CloudOS:getAllSubscriptions(); 
        owners = all_subs.values()
	                 .filter(function(sub){sub{"relationship"}.match(re/owner|fleet/i)})
	                 .map(function(sub){ sub{"eventChannel"} })
	                 ;
	owners
    };


    // --------------------------------------------

    timelineItems = function(id, limit, offset) {
      id.isnull() || id eq "" => allItems(limit, offset)
                               | ent:timeline{mkTid(id)};
    };

    allItems = function(limit, offset) {
      sort_opt = {
        "path" : ["timestamp"],
	"reverse": true,
	"compare" : "datetime"
      };

      max_returned = 25;

      hard_offset = offset.isnull() 
                 || offset eq ""        => 0               // default
                  |                        offset;

      hard_limit = limit.isnull() 
                || limit eq ""          => 10              // default
                 | limit > max_returned => max_returned
		 |                         limit; 

      global_opt = {
        "index" : hard_offset,
	"limit" : hard_limit
      }; 

      sorted_keys = this2that:transform(ent:timeline, sort_opt, global_opt);
      sorted_keys.map(function(id){ ent:timeline{id} })
    };

    rawTimeline = function() {
      ent:timeline
    };

    deliver_message = defaction(application, subject, priority, description, id) {

      // Retrieve notification level settings
      notify_level = (priority == 2)  => pds:get_config_value("notifyLevel2").defaultsTo("sms")
      		   | (priority == 1)  => pds:get_config_value("notifyLevel1").defaultsTo("email")
		   | (priority == 0)  => pds:get_config_value("notifyLevel0").defaultsTo("logonly")
		   | (priority == -1) => pds:get_config_value("notifyLevelm1").defaultsTo("nothing")
        	   | (priority == -2) => pds:get_config_value("notifyLevelm2").defaultsTo("nothing")
      		   |                     "nothing";

      // just for logging
      bad_level = notify_level eq "sms"   && phone_num().isnull()  => true.klog(">> Notify level is SMS but no phone >>")
                | notify_level eq "email" && email_addr().isnull() => true.klog(">> Notify level is Email but no email >>")
		|                                                     false;

      attenuate = function(nl) {
        my_notification_level = notificationLevel();
	new_level =  my_notification_level eq "emergency"
	          && nl eq "sms"                           => nl
	          |  my_notification_level eq "alert"
		  && (nl eq "sms" || nl eq "email")        => nl
		  |  my_notification_level eq "info"       => nl
		  |                                           "logonly";
        new_level
      };

      choose attenuate(notify_level.klog(">> original notify level >>")).klog(">> attenuated notify level  >>") {
        sms         => twilio:send_sms(phone_num(), system_number(), "#{subject} (#{application}): #{description}");
        email       => sendgrid:send(name(), email_addr(), "#{application}: #{subject}", description);
        logonly     => noop();
        nothing     => noop();
      }
    };

  }

  // ------------------------------------------------------------------------
  rule load_app_config_settings {
    select when notification initialize
    pre {
      setSchema = [
        {
          "name"     : "notifyLevel2",
          "label"    : "Urgent Priority",
          "dtype"    : "select",
          "options"  : ["sms","email", "logonly", "nothing"]
        },
        {
          "name"     : "notifyLevel1",
          "label"    : "High Priority",
          "dtype"    : "select",
          "options"  : ["sms","email", "logonly", "nothing"]
        },
        {
          "name"     : "notifyLevel0",
          "label"    : "Normal Priority",
          "dtype"    : "select",
          "options"  : ["sms","email","logonly", "nothing"]
        },
        {
          "name"     : "notifyLevelm1",
          "label"    : "Low Priority",
          "dtype"    : "select",
          "options"  : ["sms","email","logonly", "nothing"]
        },
        {
          "name"     : "notifyLevelm2",
          "label"    : "Lowest Priority",
          "dtype"    : "select",
          "options"  : ["sms","email","logonly", "nothing"]
        }
      ];
      setData = {
        "notifyLevel2"  : "sms",
        "notifyLevel1"  : "email",
        "notifyLevel0"  : "logonly",
        "notifyLevelm1" : "nothing",
        "notifyLevelm2" : "nothing"
      };
    }
    always {
      raise pds event new_settings_schema
        with setName   = "Notifications"
        and  setRID    = thisRID
        and  setSchema = setSchema
        and  setData   = setData
        and  _api = "sky";
    }
  }

  rule dispatch {
    select when notification status
    pre {

      notify_attrs = {
        "application": event:attr("application").defaultsTo("an unknown application"),
        "subject": event:attr("subject").defaultsTo("Status Notification for #{app}"),
        "priority": event:attr("priority").defaultsTo(0),
        "description" : event:attr("description").defaultsTo("A status notification with priority #{priority} was received from #{app}"),
        "id":  event:attr("id").defaultsTo(random:uuid())
      };

      local = not (email_addr().isnull() && phone_num().isnull());
    }

    if(local) then {
      noop();
    }
    fired {
      raise explicit event deliver for meta:rid() attributes notify_attrs
    } else {
      raise explicit event for_owner for meta:rid() attributes notify_attrs
    }
  }

  rule deliver {
    select when explicit deliver
    pre {
      application = event:attr("application");
      subject = event:attr("subject");
      priority = event:attr("priority");
      description = event:attr("description");
      id = event:attr("id");
    }

    deliver_message(application, subject, priority, description, id)

    always {
      log "Delivered message " + {"subject": subject, "priority": priority, "id": id}.encode();
      raise notification event new_timeline_item attributes
        {"application": application,
	 "subject": subject,
	 "priority": priority,
	 "description": description,
	 "id": id,
	 "disposition": "deliver"
	};
    }
  }

  rule route_to_owner {
    select when explicit for_owner
    foreach ownerChannels() setting(owner_eci)
      pre {
        new_attrs = event:attrs().put(["disposition"], "route_to_owner")	  
      }
      {
        send_directive("Routing to owner")
          with channel = owner_eci 
           and attrs = event:attrs();
        event:send({"cid": owner_eci}, "notification", "status")
          with attrs = event:attrs();
      }
      always {
        log "Routing to owner: " + {"subject": subject, "priority": priority, "id": id}.encode();
        raise notification event new_timeline_item attributes new_attrs;
      }
    }


    // -- timeline ----------------------------------------------------------------------
    rule timeline_remove_item {
      select when notification bad_timeline_item
      fired {
        clear ent:timeline{event:attr("id")};
      }
    }

    rule timeline_add_item {
      select when notification new_timeline_item
      pre {
        notify_attrs = event:attrs().put(["timestamp"], time:now() );
        id = event:attr("id").defaultsTo(random:uuid());
      }
      always {
        set ent:timeline{id} notify_attrs
      }
  
    }

}
