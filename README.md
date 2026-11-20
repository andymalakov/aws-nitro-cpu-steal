# aws-nitro-cpu-steal

On whole-host EC2 instances (the largest non-metal size of a family, for example `c6id.32xlarge` or `c8id.48xlarge`), the hypervisor takes **one physical core away from the guest for about 28 ms, once a minute, starting exactly on a whole wall-clock second**. Both SMT siblings of that core stop. The guest can't see this as anything other than CPU steal: no scheduler switch, no interrupt, no log.

For most workloads 28 ms per minute doesn't matter. For a latency-critical thread pinned to the affected core, it's a 28 ms freeze. We found it as a once-a-minute 22 ms stall in a trading system's order path.

This repository reproduces it on the stock Amazon Linux 2023 AMI, with no tuning and only standard tools.

## What it measures

`measure.sh` runs on the instance for N seconds (default 300) and records:

- `mpstat -P ALL 1`: `%steal` per vCPU;
- steal per vCPU from `/proc/stat`, once a second;
- a busy-loop gap detector pinned to **every** vCPU. It logs every gap over 5 ms between two consecutive clock reads, independently of the kernel's steal accounting.

`analyze.py` groups gaps of 15 ms or more by the second of the minute in which they start. For each group it lists the vCPUs hit in each minute and whether the kernel charged that time as steal.

## Results (us-east-2, November 2026, stock AL2023 with kernel 6.18)

| Instance | CPU | Second | Minutes | Gap | Cores hit, minute by minute |
|---|---|---|---|---|---|
| c6id.32xlarge | Xeon Platinum 8375C | :40.000 | every minute | 28.0 ms | 37+101 every time (same core) |
| c8id.48xlarge | Xeon 6975P-C | :29.000 | every minute | 27.4 ms | 31+127, 47+143, 94+190, 57+153, 37+133 (a different core each minute) |

Each pair is the two SMT siblings of one physical core. Steal accounting charged the same vCPUs in the same second.

The second of the minute differs from host to host; we've seen :16, :29, :36, :40 and :56. Smaller sizes (for example `.12xlarge`) didn't show the effect in our runs. Presumably the host then has cores outside the guest for its own periodic work.

Example output (`c6id.32xlarge`):

```
Gaps of 15 ms or more (excluding the first and last 15 s), grouped by the second of the minute in which they start:
  :40  4 minute(s), median 28.0 ms, STEAL; vCPUs per minute: 37+101 | 37+101 | 37+101 | 37+101
  :11  2 minute(s), median 32.3 ms, no steal; vCPUs per minute: 2 | 2
```

Groups marked "no steal" are ordinary guest noise. On the stock AMI that includes khugepaged every 10 s and an agent on a ~61 s cycle, which hit a random CPU each time.

## Running it

You need the AWS CLI with permission to run and terminate instances, plus a subnet with internet access, a security group that allows SSH from your machine, and a key pair.

```
export SUBNET_ID=subnet-... SECURITY_GROUP_ID=sg-... KEY_NAME=my-key KEY_FILE=~/.ssh/my-key.pem
INSTANCE_TYPE=c6id.32xlarge ./repro.sh
```

Optional: `REGION` (default `us-east-2`), `DURATION` in seconds (default 300), `AMI` (default: latest AL2023 from SSM), `INSTANCE_PROFILE`, `OUT`.

`repro.sh` launches the instance, uploads and runs `measure.sh`, downloads the results to `results/<type>-<timestamp>/`, terminates the instance and runs `analyze.py`. As a safety net, the instance also shuts itself down (and terminates) after 60 minutes.

Cost: one whole-host instance for about 15 minutes, a few dollars.

## Open questions

- Is this expected behaviour on whole-host Nitro instances? Is it documented?
- Can it be avoided or steered to a known core? Do `.metal` instances behave differently?
- Why was the core fixed on one host and different every minute on another?
