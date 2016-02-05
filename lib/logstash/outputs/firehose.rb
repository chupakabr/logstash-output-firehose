# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/aws_config"
require "stud/temporary"
require "stud/task"
require "socket" # for Socket.gethostname
require "thread"
require "tmpdir"
require "fileutils"

# INFORMATION:
#
# This plugin sends logstash events to Amazon Kinesis Firehose.
# To use it you need to have the proper write permissions and a valid Firehose stream.
# Make sure you have permissions to put records into Firehose stream.
# Also be sure to run logstash as super user to establish a connection.
#
# AWS SDK, Firehose client: http://docs.aws.amazon.com/sdkforruby/api/Aws/Firehose/Client.html
#
# #### Usage:
# This is an example of logstash config:
# [source,ruby]
# output {
#   firehose {
#     access_key_id => "AWS ACCESS KEY"       (required)
#     secret_access_key => "AWS SECRET KEY"   (required)
#     region => "us-west-2"                   (required)
#     stream => "firehose-stream-name"        (required)
#     codec => "json_lines"                   (optional, default 'line')
#     aws_credentials_file => "/path/file"    (optional, default: none)
#     proxy_uri => "proxy URI"                (optional, default: none)
#     use_ssl => true|false                   (optional, default: true)
#   }
# }
#

class LogStash::Outputs::Firehose < LogStash::Outputs::Base
  include LogStash::PluginMixins::AwsConfig

  TEMPFILE_EXTENSION = "txt"
  FIREHOSE_STREAM_VALID_CHARACTERS = /[\w\-]/

  config_name "firehose"

  # Output coder
  default :codec, "line"

  # Firehose stream info
  config :use_ssl, :validate => :boolean, :default => true
  config :region, :validate => :string, :default => "us-west-2"
  config :stream, :validate => :string
  config :access_key_id, :validate => :string
  config :secret_access_key, :validate => :string

  #
  # Register plugin
  public
  def register
    require "aws-sdk"
    # required if using ruby version < 2.0
    # http://ruby.awsblog.com/post/Tx16QY1CI5GVBFT/Threading-with-the-AWS-SDK-for-Ruby
    #Aws.eager_autoload!(Aws::Firehose)
    Aws.eager_autoload!(services: %w(Firehose))

    # Create Firehose API client
    @firehose = aws_firehose_client

    # Validate stream name
    if @stream.nil? || @stream.empty?
      @logger.error("Firehose: stream name is empty", :stream => @stream)
      raise LogStash::ConfigurationError, "Firehose: stream name is empty"
    end
    if @stream && @stream !~ FIREHOSE_STREAM_VALID_CHARACTERS
      @logger.error("Firehose: stream name contains invalid characters", :stream => @stream, :allowed => FIREHOSE_STREAM_VALID_CHARACTERS)
      raise LogStash::ConfigurationError, "Firehose: stream name contains invalid characters"
    end

    # Register coder: comma separated line -> SPECIFIED_CODEC_FMT, call handler after to deliver encoded data to Firehose
    @codec.on_event do |event, encoded_event|
      handle_event(encoded_event)
    end
  end

  #
  # On event received handler: just wrap as JSON and pass it to handle_event method
  public
  def receive(event)
    @codec.encode(event)
  end # def event


  #
  # Helper methods
  #

  # Build AWS Firehose client
  private
  def aws_firehose_client
    @logger.info "Registering Firehose output", :stream => @stream, :region => @region
    @firehose = Aws::Firehose::Client.new(aws_full_options)
  end

  # Build and return AWS client options map
  private
  def aws_full_options
    aws_options_hash
  end

  # Evaluate AWS endpoint for Firehose based on specified @region option
  public
  def aws_service_endpoint(region)
    return {
        :firehose_endpoint => "firehose.#{region}.amazonaws.com"
    }
  end

  # Handle encoded event, specifically deliver received event into Firehose stream
  private
  def handle_event(encoded_event)
    # TODO Multithreaded workers pool?
    push_data_into_stream encoded_event
  end

  # Push encoded data into Firehose stream
  private
  def push_data_into_stream(encoded_event)
    @logger.debug "Pushing encoded event: #{encoded_event}"

    begin
      @firehose.put_record({
        delivery_stream_name: @stream,
        record: {
            data: encoded_event
        }
      })
    rescue Aws::Errors::Base => error
      # TODO Retry policy
      # TODO Keep failed events somewhere, probably in fallback file
      @logger.error "Firehose: AWS error", :error => error
      raise LogStash::Error, "Firehose: AWS data delivery error: #{error}"
    end
  end

end # class LogStash::Outputs::Firehose