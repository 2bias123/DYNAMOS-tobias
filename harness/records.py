import json

from cluster import Failed


def parse(text):
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            raise Failed(f"record line {number} is not JSON: {line[:120]}") from None
        if not isinstance(record, dict) or type(record.get("decidedUnixMicros")) is not int:
            raise Failed(f"record line {number} has no whole decidedUnixMicros: {line[:120]}")
        found.append(record)
    return found


def since(records, start_us, op=None, decision=None):
    return [record for record in records if record["decidedUnixMicros"] >= start_us
            and (op is None or record.get("op") == op) and (decision is None or record.get("decision") == decision)]


def job_of(record):
    identity = record.get("identity") or {}
    return identity.get("jobId") or identity.get("localJobName") or ""
