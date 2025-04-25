import datetime
import enum
import logging
import os
import pathlib
import re
from typing import Annotated

import polars as pl
import typer
from azure.identity import DefaultAzureCredential
from azure.mgmt.monitor import MonitorManagementClient
from rich.logging import RichHandler

app = typer.Typer(pretty_exceptions_show_locals=False)
_logger = logging.getLogger(__name__)


class AzureResource:
    def __init__(self, subscription_id: str, resource_group: str, resource_type: str):
        self.subscription_id = subscription_id
        self.resource_group = resource_group
        self.resource_type = resource_type

    def __str__(self):
        return f"/subscriptions/{self.subscription_id}/resourceGroups/{self.resource_group}/providers/{self.resource_type}"


def parse_resource_uri(resource_uri: str) -> AzureResource:
    match = re.match(
        r"^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/(.+)$", resource_uri
    )
    if not match:
        raise typer.BadParameter(
            "Resource URI must match the format: /subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/{resource_type}"
        )
    subscription_id, resource_group, resource_type = match.groups()
    return AzureResource(
        subscription_id=subscription_id,
        resource_group=resource_group,
        resource_type=resource_type,
    )


class Interval(str, enum.Enum):
    PT1M = "PT1M"
    PT5M = "PT5M"
    PT15M = "PT15M"
    PT30M = "PT30M"
    PT1H = "PT1H"
    PT6H = "PT6H"
    PT12H = "PT12H"
    P1D = "PT1D"

    def to_timedelta(self):
        match self:
            case Interval.PT1M:
                return datetime.timedelta(minutes=1)
            case Interval.PT5M:
                return datetime.timedelta(minutes=5)
            case Interval.PT15M:
                return datetime.timedelta(minutes=15)
            case Interval.PT30M:
                return datetime.timedelta(minutes=30)
            case Interval.PT1H:
                return datetime.timedelta(hours=1)
            case Interval.PT6H:
                return datetime.timedelta(hours=6)
            case Interval.PT12H:
                return datetime.timedelta(hours=12)
            case Interval.P1D:
                return datetime.timedelta(days=1)


@app.command()
def fetch_metrics(
    resource_uri: Annotated[
        AzureResource, typer.Argument(parser=parse_resource_uri, help="Resource URI")
    ],
    debug: Annotated[
        bool, typer.Option("--debug", "-d", help="Turn on debug-level logging")
    ] = False,
    timespan: Annotated[
        str, typer.Option("--timespan", "-t", help="Timespan")
    ] = "/".join(
        [
            (
                datetime.datetime.now(datetime.timezone.utc)
                - datetime.timedelta(days=30)
            ).strftime("%Y-%m-%dT%H:%M:%SZ"),
            datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        ]
    ),
    interval: Annotated[
        Interval, typer.Option("--interval", "-i", help="Interval")
    ] = Interval.PT15M,
    metric_names: Annotated[
        list[str], typer.Option("--metric-names", "-m", help="Metric names")
    ] = [
        "cpu_percent",
        "iops", 
        "network_bytes_ingress",
        "network_bytes_egress",
    ],
    aggregations: Annotated[
        list[str], typer.Option("--aggregations", "-a", help="Aggregations")
    ] = [
        "Average",
        "Minimum",
        "Maximum",
    ],
    output_dir: Annotated[
        pathlib.Path,
        typer.Option(
            "--output-dir",
            "-O",
            help="Output directory",
            exists=True,
            file_okay=False,
            writable=True,
        ),
    ] = pathlib.Path("data"),
):
    _logger.setLevel(logging.DEBUG if debug else logging.INFO)
    _handler = RichHandler(
        level=logging.DEBUG if debug else logging.INFO,
        show_path=False,
        rich_tracebacks=True,
    )
    _logger.addHandler(_handler)

    _logger.debug("Running CLI with args: %s", locals())

    client = MonitorManagementClient(
        credential=DefaultAzureCredential(),
        subscription_id=resource_uri.subscription_id,
    )

    response = client.metrics.list(
        resource_uri=resource_uri,
        timespan=timespan,
        interval=interval.value,
        metricnames=",".join(metric_names),
        aggregation=",".join(aggregations),
    )

    for m in response.value:
        name = m.name.value
        unit = m.unit

        _logger.info("Fetching metrics for %s", name)

        values = [
            {
                "timestamp": d.time_stamp,
                "name": name,
                "unit": unit,
                **{key.lower(): getattr(d, key.lower()) for key in aggregations},
            }
            for d in m.timeseries[0].data
        ]

        _logger.info("Creating a DataFrame for %s", name)

        df = pl.DataFrame(
            values,
            schema={
                "timestamp": pl.Datetime,
                "name": pl.String,
                "unit": pl.String,
                **{key.lower(): pl.Float64 for key in aggregations},
            },
        )

        _logger.info("Writing non-null values to CSV for %s", name)

        df.drop_nulls().write_csv(
            os.path.join(output_dir, f"raw-{name.lower().replace(' ', '-')}.csv")
        )


if __name__ == "__main__":
    app()

