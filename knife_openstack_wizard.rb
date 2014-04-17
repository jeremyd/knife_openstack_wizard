require 'clustersense/agents'
require 'clustersense/wizards'
require 'json'

class AwsMenus
  include Wizards
  include Celluloid

  def initialize
    @agreements ||= {}
  end

  def main_menu()
    question = "Knife Openstack"
    menu_choices = {
      "Berks Menu" => 
          ->(response){ berks_refresh_menu() },
      "Run Chef" => 
          ->(response){ run_chef_menu() },
      "Launch Cluster" => 
          ->(response){ launch_cluster_menu() },
      "Terminate Cluster" => 
          ->(response){ terminate_cluster_menu() },
      "Unload Wizard" =>
          ->(response){ after(3) { exit(0) } }
      }
    choices(question, menu_choices.keys, true) do |choice|
      menu_choices[choice].call(choice)
    end
  end

  # receives a cookbook name to operate on
  def berks_sub_menu(cookbook_name)
    question = "Which Berks?"
    menu_choices = {
      "Berks Install" => 
          ->(response){ berks_install(cookbook_name) },
      "Berks Update" => 
          ->(response){ berks_update(cookbook_name) },
      "Berks Upload" => 
          ->(response){ berks_upload(cookbook_name) },
      "All" =>
          ->(response){ berks_refresh(cookbook_name) }

      }
    choices(question, menu_choices.keys, false) do |choice|
      menu_choices[choice].call(choice)
    end
  end

  # Provide user a list of cookbooks in COOKBOOK_DIR to upload with berks.
  def terminate_cluster_menu()
    question = "Launch a cluster"
    unless ENV['COOKBOOK_DIR']
      agree("Aborting.  You must set the environment variable COOKBOOK_DIR.  Would you like to exit the wizard?") do |answer|
        if answer =~ /yes/i
          after(3) { exit 0 } if answer =~ /yes/i
        else
          main_menu
        end
      end
    else
      menu_choices = {}
      cookbook_dirs = Dir.glob(File.join(ENV['COOKBOOK_DIR'], "*")).select {|s| File.directory?(s) }
      cookbook_dirs.each do |d|
        x = File.basename(d)
        cluster_name = "#{x}-#{ENV['mytag']}-0"
        menu_choices[x] = ->(response){ delete_if_exists(x) }
      end
      choices(question, menu_choices.keys, false) do |choice|
        menu_choices[choice].call(choice)
      end
      main_menu
    end
  end


  # Provide user a list of cookbooks in COOKBOOK_DIR to upload with berks.
  def launch_cluster_menu()
    question = "Launch a cluster"
    unless ENV['COOKBOOK_DIR']
      agree("Aborting.  You must set the environment variable COOKBOOK_DIR.  Would you like to exit the wizard?") do |answer|
        if answer =~ /yes/i
          after(3) { exit 0 } if answer =~ /yes/i
        else
          main_menu
        end
      end
    else
      menu_choices = {}
      cookbook_dirs = Dir.glob(File.join(ENV['COOKBOOK_DIR'], "*")).select {|s| File.directory?(s) }
      cookbook_dirs.each do |d|
        x = File.basename(d)
        menu_choices[x] = ->(response){ launch_cluster(x, 3) }
      end
      choices(question, menu_choices.keys, false) do |choice|
        menu_choices[choice].call(choice)
      end
      main_menu
    end
  end

  # Provide user a list of cookbooks in COOKBOOK_DIR to upload with berks.
  def berks_refresh_menu()
    question = "Refresh which cookbook?"
    unless ENV['COOKBOOK_DIR']
      agree("Aborting.  You must set the environment variable COOKBOOK_DIR.  Would you like to exit the wizard?") do |answer|
        if answer =~ /yes/i
          after(3) { exit 0 } if answer =~ /yes/i
        else
          main_menu
        end
      end
    else
      menu_choices = {}
      cookbook_dirs = Dir.glob(File.join(ENV['COOKBOOK_DIR'], "*")).select {|s| File.directory?(s) }
      cookbook_dirs.each do |d|
        x = File.basename(d)
        menu_choices[x] = ->(response){ berks_sub_menu(x); }
      end
      choices(question, menu_choices.keys, false) do |choice|
        menu_choices[choice].call(choice)
      end
    end
  end

  # overrides at runtime the environment settings and name for this cluster.
  def mod_environment(cookbook_path, env_template_name, modified_name, option_mods={})
    raw = ::IO.read(File.join(cookbook_path, "environments", env_template_name))
    mod_this = JSON::parse(raw)
    mod_this['name'] = modified_name
    return mod_this.merge(option_mods).to_json
  end

# TODO: environment search.  we have an environment per-service, and the service interdependencies need to look each other up based on your tag.
# eg. lookout-storm-tagname should store the tagname for lookout-zookeeper-tagname.json cluster to do lookups..
# or, use the same environment somehow with a combination from all cookbooks? </crazy>
  def ask_about_environment(cookbook_name, node="app2")
    cookbook_path = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    target_env_file = File.join(cookbook_path, "environments", "mytag.json")
    question = "Would you like to run with the default environment?"
    userlog("target env file is #{target_env_file}")
    agree(question) do |answer|
      if answer =~ /yes/i
# knife upload the default, launch with the default, modify the name though
        ::IO.write(target_env_file, mod_environment(cookbook_path, "stage.json", "#{cookbook_name}-#{ENV['mytag']}"))
      else
# knife upload a dynamically generated environment with modified name and launch
# TODO: actually override more options? Right now overriding tagname might be good enough..
        ::IO.write(target_env_file, mod_environment(cookbook_path, "stage.json", "#{cookbook_name}-#{ENV['mytag']}"))
      end

# perform the upload
      payload =<<EOF
        #!/bin/bash -e --login
        echo knife environment from file #{target_env_file}
        knife environment from file #{target_env_file}
EOF
      after(3) { DCell::Node[node][:basic].exec(DCell.me.id, payload) }
    end
    main_menu
  end

  def delete_if_exists(name, node="app2")
    payload =<<EOF 
      #!/bin/bash -e
      declare -a serverid
      serverid=(
        $(knife openstack server list |grep #{name}|cut -f1 -d " ")
        )
      
      for i in "${serverid[@]}"; do
        if [ "$i" ]; then
          knife openstack server delete $i --purge --yes
        fi
      done

      declare -a clientid
      clientid=(
        $(knife client list |grep #{name})
        )

      for i in "${clientid[@]}"; do
        if [ "$i" ]; then
          knife client delete $i --yes
        fi
      done
EOF
    DCell::Node[node][:basic].exec(DCell.me.id, payload)
  end

  def give_chef
    # Uhh, can't use knife openstack here duh, cause that needs a chef server (CHICKEN MEET EGG)
    #knife openstack image list |grep -i chef-server-11|cut -f1 -d " "
    image_id = "bec9d5ba-d61b-4e67-9dd5-2134e758ede9" # os0 chef-server-11 
    my_chef = "chef-server-11-#{ENV['mytag']}"
    tenant_name = "stage"
    payload =<<EOF 
        #knife openstack server create --environment #{environment_name} -f 2 -I #{image_id} --node-name #{my_chef} -S #{tenant_name} -i ~/stage.pem --no-host-key-verify -x ubuntu --nics '[{ \"net_id\": \"df18aba9-7daf-41fe-bb2a-82c586a686fc\" }]' --bootstrap-network vlan2020
EOF
    DCell::Node[node][:basic].async.exec(DCell.me.id, payload)
  end

  def run_chef_menu
    question = "Run chef-client on which cluster?"
    cookbook_dirs = Dir.glob(File.join(ENV['COOKBOOK_DIR'], "*")).select {|s| File.directory?(s) }
    menu_choices = {}
    cookbook_dirs.each do |d|
      x = File.basename(d)
      menu_choices[x] = ->(response){ run_chef(x); }
    end
    choices(question, menu_choices.keys, false) do |choice|
      menu_choices[choice].call(choice)
    end
  end

  def run_chef(cookbook_name, node="app2")
    environment_name = "#{cookbook_name}-#{ENV['mytag']}"
    cluster_name = "#{cookbook_name}-#{ENV['mytag']}-0"
    userlog("**cluster_name is #{cluster_name}")
    payload =<<EOF 
      #!/bin/bash --login -e
      knife ssh "name:#{cluster_name}*" "sudo chef-client --environment #{environment_name}" -i ~/stage.pem -a ipaddress --no-host-key-verify -x ubuntu
EOF
    DCell::Node[node][:basic].async.exec(DCell.me.id, payload)
  end

  def launch_storm(cookbook_name, cluster_size=1, node="app2")
    #image_id = "02b5d86b-7d8f-4b51-a191-9a0a15596ea6" # Precise 12.04
    image_id = "caa89f87-cae1-4354-960f-793913800aab" # service-image-38-stage , not sure why we use this.. but ZK isn't doing apt-get update.. grr 
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    environment_name = "#{cookbook_name}-#{ENV['mytag']}"
    tenant_name = "stage"
    cluster_name = "#{cookbook_name}-#{ENV['mytag']}-0"

    delete_if_exists(cluster_name)

    runlist = ""
    cluster_size.times do |cid|
      if cid == 0
        runlist = "recipe[#{cookbook_name}::deploy],recipe[storm::nimbus],recipe[storm::ui]"
      elsif cid == 1
        runlist = "recipe[#{cookbook_name}::deploy],recipe[storm::supervisor]"
      elsif cid == 2
        runlist = "recipe[#{cookbook_name}::deploy],recipe[storm::drpc]"
      end
      payload =<<EOF
        knife openstack server create --environment #{environment_name} -f 2 -I #{image_id} --node-name #{cluster_name}-#{cid} -S #{tenant_name} -i ~/stage.pem --no-host-key-verify -r \"#{runlist}\" -x ubuntu --nics '[{ \"net_id\": \"df18aba9-7daf-41fe-bb2a-82c586a686fc\" }]' --bootstrap-network vlan2020 --user-data ~/user-data/staging_users.cloud_config
EOF
      DCell::Node[node][:basic].async.exec(DCell.me.id, payload)
    end
  end

  def launch_generic(cookbook_name, cluster_size=1, node="app2")
    #image_id = "02b5d86b-7d8f-4b51-a191-9a0a15596ea6" # Precise 12.04
    image_id = "caa89f87-cae1-4354-960f-793913800aab" # service-image-38-stage , not sure why we use this.. but ZK isn't doing apt-get update.. grr 
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    environment_name = "#{cookbook_name}-#{ENV['mytag']}"
    tenant_name = "stage"
    cluster_name = "#{cookbook_name}-#{ENV['mytag']}-0"

    delete_if_exists(cluster_name)

    cluster_size.times do |cid|
      payload =<<EOF 
        knife openstack server create --environment #{environment_name} -f 2 -I #{image_id} --node-name #{cluster_name}-#{cid} -S #{tenant_name} -i ~/stage.pem --no-host-key-verify -r \"recipe[#{cookbook_name}::deploy]\" -x ubuntu --nics '[{ \"net_id\": \"df18aba9-7daf-41fe-bb2a-82c586a686fc\" }]' --bootstrap-network vlan2020
EOF
      DCell::Node[node][:basic].async.exec(DCell.me.id, payload)
    end
  end

  def launch_cluster(cookbook_name, cluster_size=1, node="app2")
    if cookbook_name == "lookout-storm"
      launch_storm(cookbook_name, cluster_size, node)
    else
      launch_generic(cookbook_name, cluster_size, node)
    end
  end

  def berks_refresh(cookbook_name, node="app2")
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    payload =<<EOF
      #!/bin/bash -e --login
      echo "changing dir to #{working_dir}"
      cd #{working_dir}
      berks install
      berks update
      #berks upload #{cookbook_name} --force
      berks upload --force
EOF
    DCell::Node[node][:basic].exec(DCell.me.id, payload)
    ask_about_environment(cookbook_name)
  end

  def berks_install(cookbook_name, node="app2")
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    payload =<<EOF
      #!/bin/bash -e --login
      echo "changing dir to #{working_dir}"
      cd #{working_dir}
      berks install
EOF
    DCell::Node[node][:basic].exec(DCell.me.id, payload)
    main_menu
  end

  def berks_update(cookbook_name, node="app2")
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    payload =<<EOF
      #!/bin/bash -e --login
      echo "changing dir to #{working_dir}"
      cd #{working_dir}
      berks update
EOF
    DCell::Node[node][:basic].exec(DCell.me.id, payload)
    ask_about_environment(cookbook_name)
  end

  def berks_upload(cookbook_name, node="app2")
    working_dir = File.join(ENV['COOKBOOK_DIR'], cookbook_name)
    payload =<<EOF
      #!/bin/bash -e --login
      echo "changing dir to #{working_dir}"
      cd #{working_dir}
      #berks upload #{cookbook_name} --force
      berks upload --force
EOF
    DCell::Node[node][:basic].exec(DCell.me.id, payload)
    ask_about_environment(cookbook_name)
  end
end

config_file = @trollop_options[:config]
config = Clustersense::config(config_file)
DCell.start :id => config["node_id"], :addr => "tcp://#{config["node_ip"]}:#{config["port"]}", "registry" => { "adapter" => "zk", "servers" => [config["registry_host"]], "port" => 2181 }

AwsMenus.supervise_as :ping

DCell::Node[config["node_id"]][:ping].main_menu
