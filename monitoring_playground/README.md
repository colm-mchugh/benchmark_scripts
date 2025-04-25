## Setup
```
$ python3 -m venv ~/.uv
$ source ~/.uv/bin/activate
$ python3 -m pip install --upgrade --no-cache-dir pip setuptools uv
$ deactivate # here, you should add ~/.uv/bin to your PATH in your SHELL
$ uv run python fetch_metrics.py --help
```

## Usage

Run `az login` and select the subscription for your resources
```
$ az login
```

Fetch metrics for a Flex instance:

```
$ uv run python fetch_metrics.py -t 2025-04-24T17:30:00Z/2025-04-25T05:30:00Z \
  /subscriptions/88abe223-c630-4f2c-8782-00bb5be874f6/resourceGroups/colm-citusdata-resource/providers/Microsoft.DBforPostgreSQL/flexibleServers/ec8
[04/25/25 11:58:43] INFO     Fetching metrics for cpu_percent
                    INFO     Creating a DataFrame for cpu_percent
                    INFO     Writing non-null values to CSV for cpu_percent
[04/25/25 11:58:44] INFO     Fetching metrics for iops
                    INFO     Creating a DataFrame for iops
                    INFO     Writing non-null values to CSV for iops
                    INFO     Fetching metrics for network_bytes_ingress
                    INFO     Creating a DataFrame for network_bytes_ingress
                    INFO     Writing non-null values to CSV for network_bytes_ingress
                    INFO     Fetching metrics for network_bytes_egress
                    INFO     Creating a DataFrame for network_bytes_egress
                    INFO     Writing non-null values to CSV for network_bytes_egress
```

If the resource is not a `Microsoft.DBforPostgreSQL` resource, you may need to specify metric names; for example, `Microsoft.Compute` resources use different metric names:

```
$ uv run python fetch_metrics.py -t 2025-04-24T17:30:00Z/2025-04-25T05:30:00Z  \
/subscriptions/88abe223-c630-4f2c-8782-00bb5be874f6/resourceGroups/colm-citusdata-resource/providers/Microsoft.Compute/virtualMachines/colm-bmrunner \
--metric-names "Percentage CPU,Network In,Network Out"
```

