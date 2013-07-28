#!/usr/bin/env ruby

require 'socket'
require 'time'

module Gearman

# = TaskSet
#
# == Description
# A set of tasks submitted to a Gearman job server.
class TaskSet
  def initialize(client)
    @client = client
    @task_waiting_for_handle = nil
    @tasks_in_progress = {}  # "host:port//handle" -> [job1, job2, ...]
    @finished_tasks = []  # tasks that have completed or failed
    @sockets = {}  # "host:port" -> Socket
    @merge_hash_to_hostport = {}  # Fixnum -> "host:port"
  end

  ##
  # Add a new task to this TaskSet.
  #
  # @param args  either a Task or arguments for Task.new
  # @return      true if the task was created successfully, false otherwise
  def add_task(*args)
    task = Util::get_task_from_args(*args)
    add_task_internal(task, true)
  end

  ##
  # Internal function to add a task.
  #
  # @param task         Task to add
  # @param reset_state  should we reset task state?  true if we're adding a
  #                     new task; false if we're rescheduling one that's
  #                     failed
  # @return             true if the task was created successfully, false
  #                     otherwise
  def add_task_internal(task, reset_state=true)
    task.reset_state if reset_state
    req = task.get_submit_packet()

    @task_waiting_for_handle = task

    # Target the same job manager when submitting jobs
    # with the same unique id so that we can coalesce
    merge_hash = task.get_uniq_hash

    while (@task_waiting_for_handle != nil)
      begin
        # Try to connect again to the same server based on the unique hash
        @merge_hash_to_hostport[merge_hash] ||= @client.get_job_server
        hostport = @merge_hash_to_hostport[merge_hash]

        # Cache the socket
        @sockets[hostport] ||= @client.get_socket(hostport)

        # Submit job to server
        sock = @sockets[hostport]
        Util.logger.debug "GearmanRuby: Using socket #{sock.inspect} for #{hostport} to SUBMIT_JOB"
        Util.send_request(sock, req)

        # read_packet will fire off handle_job_created and set @task_waiting_for_handle to nil
        # TODO: Better way of doing this.
        read_packet(sock, @client.task_create_timeout_sec)
      rescue NetworkError
        Util.logger.debug "GearmanRuby: Network error on read from #{hostport} while adding job, marking server bad"
        # Tell the client this is a bad server
        @client.signal_bad_server(hostport)
        if(sock != nil)
          @client.close_socket(sock)
        end

        # Un-cache socket
        @sockets.delete hostport
        # Remove from hash -> hostport mapping
        @merge_hash_to_hostport[merge_hash] = nil
      rescue NoJobServersError
        Util.logger.error "GearmanRuby: No servers available."
        return false
      end
    end

    return true
  end
  private :add_task_internal

  ##
  # Handle a 'job_created' response from a job server.
  #
  # @param hostport  "host:port" of job server
  # @param data      data returned in packet from server
  def handle_job_created(hostport, data)
    Util.logger.debug "GearmanRuby: Got job_created with handle #{data} from #{hostport}"

    if not @task_waiting_for_handle
      raise ProtocolError, "Got unexpected job_created notification with handle #{data} from #{hostport}"
    end

    js_handle = Util.handle_to_str(hostport, data)
    task = @task_waiting_for_handle
    @task_waiting_for_handle = nil
    if(task.background)
      @finished_tasks << task
    else
      (@tasks_in_progress[js_handle] ||= []) << task
    end
    task.handle_created(data)
    nil
  end
  private :handle_job_created

  ##
  # Handle a 'work_complete' response from a job server.
  #
  # @param hostport  "host:port" of job server
  # @param data      data returned in packet from server
  def handle_work_complete(hostport, data)
    handle, data = data.split("\0", 2)
    Util.logger.debug "GearmanRuby: Got work_complete with handle #{handle} and #{data ? data.size : '0'} byte(s) of data from #{hostport}"
    tasks_in_progress(hostport, handle, true).each do |t|
      t.handle_completion(data)
      @finished_tasks << t
    end
    nil
  end
  private :handle_work_complete

  ##
  # Handle a 'work_exception' response from a job server.
  #
  # @param hostport  "host:port" of job server
  # @param data      data returned in packet from server
  def handle_work_exception(hostport, data)
    handle, exception = data.split("\0", 2)
    Util.logger.debug "GearmanRuby: Got work_exception with handle #{handle} from #{hostport}: '#{exception}'"
    tasks_in_progress(hostport, handle).each {|t| t.handle_exception(exception) }
  end
  private :handle_work_exception

  ##
  # Handle a 'work_fail' response from a job server.
  #
  # @param hostport  "host:port" of job server
  # @param data      data returned in packet from server
  def handle_work_fail(hostport, data)
    Util.logger.debug "GearmanRuby: Got work_fail with handle #{data} from #{hostport}"
    tasks_in_progress(hostport, data, true).each do |t|
      if t.handle_failure
        add_task_internal(t, false)
      else
        @finished_tasks << t
      end
    end
  end
  private :handle_work_fail

  ##
  # Handle a 'work_status' response from a job server.
  #
  # @param hostport  "host:port" of job server
  # @param data      data returned in packet from server
  def handle_work_status(hostport, data)
    handle, num, den = data.split("\0", 3)
    Util.logger.debug "GearmanRuby: Got work_status with handle #{handle} from #{hostport}: #{num}/#{den}"
    tasks_in_progress(hostport, handle).each {|t| t.handle_status(num, den) }
  end
  private :handle_work_status

  ##
  # Handle a 'work_warning' response from a job server.
  #
  # @param hostport "host:port" of job server
  # @param data     data returned in packet from server
  def handle_work_warning(hostport, data)
    handle, message = data.split("\0", 2)
    Util.logger.debug "GearmanRuby: Got work_warning with handle #{handle} from #{hostport}: '#{message}'"
    tasks_in_progress(hostport, handle).each {|t| t.handle_warning(message) }
  end
  private :handle_work_warning

  ##
  # Handle a 'work_data' response from a job server
  #
  # @param hostport  "host:port" of a job server
  # @param data       data returned in packet from server
  def handle_work_data(hostport, data)
    handle, data = data.split("\0", 2)
    Util.logger.debug "GearmanRuby: Got work_data with handle #{handle} and #{data ? data.size : '0'} byte(s) of data from #{hostport}"

    js_handle = Util.handle_to_str(hostport, handle)
    tasks = @tasks_in_progress[js_handle]
    if not tasks
      raise ProtocolError, "Got unexpected work_data with handle #{handle} from #{hostport} (no task by that name)"
    end
    tasks.each {|t| t.handle_data(data) }
  end
  private :handle_work_data

  ##
  # Read and process a packet from a socket.
  #
  # @param sock  socket connected to a job server
  def read_packet(sock, timeout=nil)
    hostport = @client.get_hostport_for_socket(sock)
    if not hostport
      raise RuntimeError, "Client doesn't know host/port for socket " +
        sock.inspect
    end
    type, data = Util.read_response(sock, timeout)
    known_types = [ :job_created,
                    :work_complete,
                    :work_fail,
                    :work_status,
                    :work_exception,
                    :work_warning,
                    :work_data ]

    if known_types.include?(type)
      send("handle_#{type}".to_sym, hostport, data)
    else
      Util.logger.debug "GearmanRuby: Got #{type.to_s} from #{hostport}"
    end
    nil
  end
  private :read_packet

  ##
  # Wait for all tasks in the set to finish.
  #
  # @param timeout  maximum amount of time to wait, in seconds
  def wait(timeout = 1)
    end_time = if timeout
      Time.now.to_f + timeout
    else
      nil
    end

    while not @tasks_in_progress.empty?
      remaining = if end_time
        (t = end_time - Time.now.to_f) > 0 ? t : 0
      else
        nil
      end

      ready_socks = remaining == 0 ? nil : IO::select(@sockets.values, nil, nil, remaining)
      if not ready_socks or not ready_socks[0]
        Util.logger.debug "GearmanRuby: Timed out while waiting for tasks to finish"
        # not sure what state the connections are in, so just be lame and
        # close them for now
        @sockets.values.each {|s| @client.close_socket(s) }
        @sockets = {}
        return false
      end

      ready_socks[0].each do |sock|
        begin
           read_packet(sock, (end_time ? end_time - Time.now.to_f : nil))
        rescue ProtocolError
          hostport = @client.get_hostport_for_socket(sock)
          Util.logger.debug "GearmanRuby: Ignoring bad packet from #{hostport}"
        rescue NetworkError
          hostport = @client.get_hostport_for_socket(sock)
          Util.logger.debug "GearmanRuby: Network error on read from #{hostport}"
        end
      end
    end

    @sockets.values.each {|s| @client.return_socket(s) }
    @sockets = {}
    @finished_tasks.each do |t|
      if ( (t.background.nil? || t.background == false) && !t.successful)
        Util.logger.debug "GearmanRuby: TaskSet failed"
        return false
      end
    end
    true
  end

  private
    def tasks_in_progress(hostport, handle, remove_task = false)
      js_handle = Util.handle_to_str(hostport, handle)
      tasks = remove_task ? @tasks_in_progress.delete(js_handle) : @tasks_in_progress[js_handle]
      if not tasks
        raise ProtocolError, "Got unexpected work_data with handle #{handle} from #{hostport} (no task by that name)"
      end
      tasks
    end
end

end
