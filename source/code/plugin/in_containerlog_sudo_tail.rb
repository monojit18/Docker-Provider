
require 'yajl'
require 'fluent/input'
require 'fluent/event'
require 'fluent/config/error'
require 'fluent/parser'
require 'open3'
require 'json'
require_relative 'omslog'
require_relative 'KubernetesApiClient'

module Fluent
  class ContainerLogSudoTail < Input
    Plugin.register_input('containerlog_sudo_tail', self)

    def initialize
      super
      @command = nil
      @paths = []
      #Using this to construct the file path for all every container json log file.	
      #Example container log file path -> /var/lib/docker/containers/{ContainerID}/{ContainerID}-json.log	
      #We have read permission on this file but don't have execute permission on the below mentioned path. Hence wildcard character searches to find the container ID's doesn't work.	
      @containerLogFilePath = "/var/lib/docker/containers/"
      #This folder contains a list of all the containers running/stopped and we're using it to get all the container ID's which will be needed for the log file path below
      #TODO : Use generic path from docker REST endpoint and find a way to mount the correct folder in the omsagent.yaml	    
      @containerIDFilePath = "/var/opt/microsoft/docker-cimprov/state/ContainerInventory/*"
      @@systemPodsNamespace = 'kube-system'
      @@getSystemPodsTimeIntervalSecs = 300 #refresh system container list every 5 minutes
      @@lastSystemPodsGetTime = nil;
      @@systemContainerIDList = Hash.new
      @@disableKubeSystemLogCollection = ENV['DISABLE_KUBE_SYSTEM_LOG_COLLECTION']
      if !@@disableKubeSystemLogCollection.nil? && !@@disableKubeSystemLogCollection.empty? && @@disableKubeSystemLogCollection.casecmp('true') == 0
        @@disableKubeSystemLogCollection = 'true'
        $log.info("in_container_sudo_tail : System container log collection is disabled")
      else
        @@disableKubeSystemLogCollection = 'false'
        $log.info("in_container_sudo_tail : System container log collection is enabled")
      end
    end

    attr_accessor :command

    #The format used to map the program output to the incoming event.
    config_param :format, :string, default: 'none'

    #Tag of the event.
    config_param :tag, :string, default: nil

    #Fluentd will record the position it last read into this file.
    config_param :pos_file, :string, default: nil

    #The interval time between periodic program runs.
    config_param :run_interval, :time, default: nil

    BASE_DIR = File.dirname(File.expand_path('..', __FILE__))
    RUBY_DIR = BASE_DIR + '/ruby/bin/ruby '
    TAILSCRIPT = BASE_DIR + '/plugin/containerlogtailfilereader.rb '

    def configure(conf)
      super
      unless @pos_file
        raise ConfigError, "'pos_file' is required to keep track of file"
      end 

      unless @tag 
        raise ConfigError, "'tag' is required on sudo tail"
      end

      unless @run_interval
        raise ConfigError, "'run_interval' is required for periodic tailing"      
      end
 
      @parser = Plugin.new_parser(conf['format'])
      @parser.configure(conf)
    end

    def start
      @finished = false
      @thread = Thread.new(&method(:run_periodic))
    end

    def shutdown
      @finished = true 
      @thread.join
    end

    def receive_data(line)
      es = MultiEventStream.new
      begin
        line.chomp!  # remove \n
        @parser.parse(line) { |time, record|
          if time && record
            es.add(time, record)
          else
            $log.warn "pattern doesn't match: #{line.inspect}"
          end
          unless es.empty?
            tag=@tag
            router.emit_stream(tag, es)
          end
        }
      rescue => e
        $log.warn line.dump, error: e.to_s
        $log.debug_backtrace(e.backtrace)
      end
    end

    def receive_log(line)
      $log.warn "#{line}" if line.start_with?('WARN')
      $log.error "#{line}" if line.start_with?('ERROR')
      $log.info "#{line}" if line.start_with?('INFO')
    end
 
    def readable_path(path)
      if system("sudo test -r #{path}")
        OMS::Log.info_once("Following tail of #{path}")
        return path
      else
        OMS::Log.warn_once("#{path} is not readable. Cannot tail the file.")
	return ""
      end
    end

    def set_system_command
      timeNow = DateTime.now
      cName = "Unkown"
      tempContainerInfo = {}
      paths = ""
      
      #if we are on agent & system containers log collection is disabled, get system containerIDs to exclude logs from containers in system containers namespace from being tailed 
      if !KubernetesApiClient.isNodeMaster && @@disableKubeSystemLogCollection.casecmp('true') == 0 
        if @@lastSystemPodsGetTime.nil? || ((timeNow - @@lastSystemPodsGetTime)*24*60*60).to_i >= @@getSystemPodsTimeIntervalSecs
          $log.info("in_container_sudo_tail : System Container list last refreshed at #{@@lastSystemPodsGetTime} - refreshing now at #{timeNow}")
          sysContainers = KubernetesApiClient.getContainerIDs(@@systemPodsNamespace)
          #BugBug - https://msecg.visualstudio.com/OMS/_workitems/edit/215107 - we get 200 with empty payload from time to time
          if (!sysContainers.nil? && !sysContainers.empty?)
            @@systemContainerIDList = sysContainers
          else
            $log.info("in_container_sudo_tail : System Container ID List is empty!!!! Continuing to use currently cached list.")
          end
          @@lastSystemPodsGetTime = timeNow
          $log.info("in_container_sudo_tail : System Container ID List: #{@@systemContainerIDList}")
        end
      end
      
      Dir.glob(@containerIDFilePath).select { |p|
        cName = p.split('/').last;
        if !@@systemContainerIDList.key?("docker://" + cName)
	        p = @containerLogFilePath + cName + "/" + cName + "-json.log"
          paths += readable_path(p) + " "
        else
          $log.info("in_container_sudo_tail : Excluding system container with ID #{cName} from tailng for log collection")
        end
      }
      if !system("sudo test -r #{@pos_file}")
	      system("sudo touch #{@pos_file}")
      end
      @command = "sudo " << RUBY_DIR << TAILSCRIPT << paths <<  " -p #{@pos_file}"
    end

    def run_periodic
      until @finished
        begin
          sleep @run_interval
          #if we are on master & system containers log collection is disabled, collect nothing (i.e NO COntainer log collection for ANY container)
          #we will be not collection omsagent log as well in this case, but its insignificant & okay!
          if !KubernetesApiClient.isNodeMaster || @@disableKubeSystemLogCollection.casecmp('true') != 0 
            set_system_command
            Open3.popen3(@command) {|writeio, readio, errio, wait_thread|
              writeio.close
              while line = readio.gets
                receive_data(line)
              end
              while line = errio.gets
                receive_log(line)
              end
              
              wait_thread.value #wait until child process terminates
            }
          end
        rescue
          $log.error "containerlog_sudo_tail failed to run or shutdown child proces", error => $!.to_s, :error_class => $!.class.to_s
          $log.warn_backtrace $!.backtrace
        end
      end
    end
  end

end
