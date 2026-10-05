"""RunPod serverless handler for DeepRank-Ab.

Wraps the installed `deeprank-ab-predict` command line tool. Runs in its own
venv (runpod's requests>=2.31 conflicts with deeprank-ab's pins), so it only
uses the standard library plus runpod.

Job input (``job["input"]``), give ONE of:
    "pdb":        PDB file contents as plain text (single model or ensemble)
    "pdb_base64": base64-encoded PDB file
    "pdb_url":    http(s) URL to download the PDB file from

Optional chain overrides (auto-detected via ANARCI when omitted):
    "heavy_chain_id": "H", "light_chain_id": "L" (or "-" for nanobodies),
    "antigen_chain_id": "A"

Returns ``{"predictions": [...]}``, one row per model of the predictions CSV
(pdb_id, predicted_dockq, HL_contact_flag, vdw_clash_flag), best first.
"""

import base64
import csv
import os
import subprocess
import tempfile
import urllib.request
from pathlib import Path

import runpod

PREDICT_BIN = "/app/.venv/bin/deeprank-ab-predict"
TIMEOUT = int(os.environ.get("DEEPRANK_AB_TIMEOUT", "3600"))
MAX_DOWNLOAD_BYTES = int(
    os.environ.get("DEEPRANK_AB_MAX_DOWNLOAD_BYTES", str(500 * 1024**2))
)
CHAIN_OPTIONS = ("heavy_chain_id", "light_chain_id", "antigen_chain_id")


def _get_pdb_bytes(job_input):
    given = [k for k in ("pdb", "pdb_base64", "pdb_url") if job_input.get(k)]
    if len(given) != 1:
        raise ValueError("Provide exactly one of 'pdb', 'pdb_base64' or 'pdb_url'")
    key = given[0]
    value = job_input[key]
    if key == "pdb":
        return value.encode()
    if key == "pdb_base64":
        return base64.b64decode(value)
    if not value.startswith(("http://", "https://")):
        raise ValueError("'pdb_url' must be an http(s) URL")
    with urllib.request.urlopen(value, timeout=300) as resp:
        data = resp.read(MAX_DOWNLOAD_BYTES + 1)
    if len(data) > MAX_DOWNLOAD_BYTES:
        raise ValueError(f"'pdb_url' is larger than {MAX_DOWNLOAD_BYTES} bytes")
    return data


def handler(job):
    job_input = job.get("input") or {}
    try:
        pdb_bytes = _get_pdb_bytes(job_input)
        with tempfile.TemporaryDirectory() as workdir:
            name = Path(str(job_input.get("name") or "input")).stem or "input"
            pdb_path = Path(workdir) / f"{name}.pdb"
            pdb_path.write_bytes(pdb_bytes)

            cmd = [PREDICT_BIN, str(pdb_path)]
            for opt in CHAIN_OPTIONS:
                if job_input.get(opt):
                    cmd += [f"--{opt}", str(job_input[opt])]

            # The CLI writes its workspace into the current directory
            proc = subprocess.run(
                cmd, cwd=workdir, capture_output=True, text=True, timeout=TIMEOUT
            )
            csvs = list(Path(workdir).glob("*-deeprank_ab_pred_*/*_predictions.csv"))
            if proc.returncode != 0 or not csvs:
                return {
                    "error": "DeepRank-Ab failed",
                    "returncode": proc.returncode,
                    "stderr": proc.stderr[-4000:],
                    "stdout": proc.stdout[-4000:],
                }

            with open(csvs[0], newline="") as fh:
                rows = list(csv.DictReader(fh))
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        return {"error": str(exc)}

    for row in rows:
        if row.get("predicted_dockq"):
            row["predicted_dockq"] = float(row["predicted_dockq"])
    return {"predictions": rows}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
