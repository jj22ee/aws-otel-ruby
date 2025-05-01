require 'json'

require 'opentelemetry-sdk'
require 'aws/distro/opentelemetry/exporter/xray/udp'
require 'opentelemetry/propagator/xray'
require 'json'

# Initialize OpenTelemetry SDK outside handler (runs once during cold start)
OpenTelemetry::SDK.configure do |c|
  c.service_name = 'test_ruby_name'

  # Configure the AWS Distro for OpenTelemetry X-Ray Lambda exporter
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
      AWS::Distro::OpenTelemetry::Exporter::XRay::UDP::AWSXRayUDPSpanExporter.new
    )
  )
  
  # Configure Lambda propagator
  c.propagators = [LambdaTextMapPropagator.new]
  
  # Set minimal resource information
  c.resource = OpenTelemetry::SDK::Resources::Resource.create({
    OpenTelemetry::SemanticConventions::Resource::SERVICE_NAME => ENV['AWS_LAMBDA_FUNCTION_NAME']
  })

  c.use 'OpenTelemetry::Instrumentation::AwsLambda'
end

module LambdaFunctions

  class Handler
    extend OpenTelemetry::Instrumentation::AwsLambda::Wrap

    def self.process(event:, context:)
      "Hello!"
    end

    instrument_handler :process
  end
end

class LambdaTextMapPropagator < OpenTelemetry::Propagator::XRay::TextMapPropagator
  AWS_TRACE_HEADER_ENV_KEY = '_X_AMZN_TRACE_ID'
  def extract(carrier, context: Context.current, getter: Context::Propagation.text_map_getter)
    # Check if the original input context already has a valid span
    span_context = Trace.current_span(context).context
    # If original context is valid, just return it - do not extract from carrier
    return context if span_context.valid?

    # First try to extract from the carrier using the standard X-Ray propagator
    xray_context = super

    # Check if we successfully extracted a context from the carrier
    span_context = Trace.current_span(xray_context).context
    return xray_context if span_context.valid?

    # If not, check for the Lambda environment variable
    trace_header = ENV.fetch(AWS_TRACE_HEADER_ENV_KEY, nil)
    return xray_context unless trace_header

    # Create a carrier with the trace header and extract from it
    env_carrier = { XRAY_CONTEXT_KEY => trace_header }
    super(env_carrier, context: xray_context, getter: getter)
  rescue OpenTelemetry::Error
    context
  end
end
