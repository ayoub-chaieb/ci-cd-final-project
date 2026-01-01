"""
Service Package
"""
import os
from flask import Flask
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

app = Flask(__name__)

# -------------------------------
# OpenTelemetry initialization
# -------------------------------
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "cicd-app")
})

trace.set_tracer_provider(TracerProvider(resource=resource))

otlp_endpoint = os.getenv(
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "otel-collector:4317"
)

otlp_exporter = OTLPSpanExporter(
    endpoint=otlp_endpoint,
    insecure=True  # OK for lab/sandbox
)

span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# Instrument Flask AFTER app creation
FlaskInstrumentor().instrument_app(app)

# This must be imported after the Flask app is created
from service import routes               # pylint: disable=wrong-import-position,cyclic-import
from service.common import log_handlers  # pylint: disable=wrong-import-position

log_handlers.init_logging(app, "gunicorn.error")

app.logger.info(70 * "*")
app.logger.info("  S E R V I C E   R U N N I N G  ".center(70, "*"))
app.logger.info(70 * "*")
