#!/usr/bin/env python3
"""email-sent-python.py - e-mail each repository's update report to its POC (To) and developers (CC).

Reads config/repositories.csv (Repo_Name, Repo_Link, POC, Email, CC_Email, Token_Name) and, for every repository,
sends reports/<Repo_Name>-report-<dd-mon-yyyy>.txt (today's report written by docker-update.sh) in ONE e-mail:
  To  = `Email` column      CC = `CC_Email` column      body = the full report + the report attached as .txt

Settings (environment variables - nothing is stored in files):
  SMTP_SERVER, SMTP_PORT (default 587), SMTP_USERNAME, SMTP_PASSWORD, EMAIL_FROM
  SMTP_SECURITY   auto (default: 465 = SSL, otherwise STARTTLS when offered) | ssl | starttls | none
  TEST_MODE=true  (or --dry-run) nothing is sent; the would-be recipients/subject are printed
  REPOSITORIES    optional comma separated Repo_Name filter (same as docker-update.sh)
  CONFIG_FILE, REPORTS_DIR, REPORT_DATE (dd-mon-yyyy, default today)

Exit codes: 0 ok | 1 at least one e-mail could not be sent | 2 configuration error.   Python 3.8+, standard library only.
"""
import argparse
import csv
import html
import os
import re
import smtplib
import ssl
import sys
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path

HERE = Path(__file__).resolve().parent
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def is_true(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "y")


def safe_name(name):                      # must match safe_name() in docker-update.sh
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def split_addresses(text):
    """'a@x.com; B@X.com, c@x.com' -> ['a@x.com', 'B@X.com', 'c@x.com'] (invalid entries returned separately)."""
    good, bad = [], []
    for part in re.split(r"[,;\s]+", text or ""):
        part = part.strip().strip("<>")
        if not part:
            continue
        (good if EMAIL_RE.match(part) else bad).append(part)
    return good, bad


def recipients(row):
    """To / CC lists: de-duplicated case-insensitively; an address in both columns stays in To only."""
    to_ok, to_bad = split_addresses(row.get("email", ""))
    cc_ok, cc_bad = split_addresses(row.get("cc_email", ""))
    seen, to, cc = set(), [], []
    for addr in to_ok:
        if addr.lower() not in seen:
            seen.add(addr.lower()); to.append(addr)
    for addr in cc_ok:
        if addr.lower() not in seen:
            seen.add(addr.lower()); cc.append(addr)
    return to, cc, to_bad + cc_bad


def read_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for raw in csv.DictReader(fh):
            row = {(k or "").strip().lower(): (v or "").strip() for k, v in raw.items()}
            if row.get("repo_name") and not row["repo_name"].startswith("#"):
                yield row


def report_value(text, label):
    m = re.search(rf"^{re.escape(label)}:\s*(.+)$", text, re.M)
    return m.group(1).strip() if m else ""


def build_message(row, report_path, sender, to, cc):
    text = report_path.read_text(encoding="utf-8", errors="replace")
    name = row["repo_name"]
    status = report_value(text.split("Repo Dockerfile Image Update Summary:")[-1], "Overall Status") or "UNKNOWN"
    pending = report_value(text, "Pending (update proposed, not applied) Images") or "0"
    updated = report_value(text, "Updated Images") or "0"
    major = report_value(text, "Major Upgrade Recommendations") or "0"
    subject = f"Docker Image Update Report - {name} - {report_value(text, 'Date') or datetime.now().strftime('%Y-%m-%d')}"
    greeting = row.get("poc") or "team"
    intro = (f"Hello {greeting},\n\n"
             f"Please find the Docker image update report for repository '{name}' below (also attached as {report_path.name}).\n"
             f"Overall status: {status} | Updated images: {updated} | Pending updates: {pending} | Major upgrade recommendations: {major}\n"
             f"Pending updates are proposals - nothing was changed unless the status says UPDATED.\n\n"
             f"{'=' * 78}\n")
    body = intro + text + "\n\nThis is an automated message.\n"
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    msg.set_content(body)
    msg.add_alternative("<html><body><pre style=\"font-family:Consolas,'Courier New',monospace;font-size:12px\">"
                        + html.escape(body) + "</pre></body></html>", subtype="html")
    msg.add_attachment(text.encode("utf-8"), maintype="text", subtype="plain", filename=report_path.name)
    return msg


def send(msg, to, cc, server, port, user, password, security):
    context = ssl.create_default_context()
    if security == "ssl" or (security == "auto" and port == 465):
        smtp = smtplib.SMTP_SSL(server, port, timeout=60, context=context)
    else:
        smtp = smtplib.SMTP(server, port, timeout=60)
    with smtp:
        smtp.ehlo()
        if security != "none" and not isinstance(smtp, smtplib.SMTP_SSL) and smtp.has_extn("starttls"):
            smtp.starttls(context=context)
            smtp.ehlo()
        elif security == "starttls" and not isinstance(smtp, smtplib.SMTP_SSL):
            raise smtplib.SMTPNotSupportedError("server does not offer STARTTLS")
        if user:
            smtp.login(user, password)
        smtp.send_message(msg, to_addrs=to + cc)


def main():
    ap = argparse.ArgumentParser(description="E-mail the per-repository Docker update reports to the POCs.")
    ap.add_argument("--config", default=os.environ.get("CONFIG_FILE", str(HERE / "config" / "repositories.csv")))
    ap.add_argument("--reports-dir", default=os.environ.get("REPORTS_DIR", str(HERE / "reports")))
    ap.add_argument("--dry-run", action="store_true", help="print what would be sent, send nothing (also TEST_MODE=true)")
    args = ap.parse_args()

    dry = args.dry_run or is_true(os.environ.get("TEST_MODE"))
    date = os.environ.get("REPORT_DATE") or datetime.now().strftime("%d-%b-%Y").lower()
    only = {x.strip().lower() for x in os.environ.get("REPOSITORIES", "").split(",") if x.strip()}
    server, user = os.environ.get("SMTP_SERVER", ""), os.environ.get("SMTP_USERNAME", "")
    password, sender = os.environ.get("SMTP_PASSWORD", ""), os.environ.get("EMAIL_FROM", "")
    security = os.environ.get("SMTP_SECURITY", "auto").lower()
    try:
        port = int(os.environ.get("SMTP_PORT", "587"))
    except ValueError:
        print("SMTP_PORT must be a number", file=sys.stderr); return 2
    if not Path(args.config).is_file():
        print(f"config file not found: {args.config}", file=sys.stderr); return 2
    if not dry and not (server and sender):
        print("SMTP_SERVER and EMAIL_FROM must be set (or use TEST_MODE=true)", file=sys.stderr); return 2

    sent = failed = skipped = 0
    for row in read_rows(args.config):
        name = row["repo_name"]
        if only and name.lower() not in only:
            continue
        report = Path(args.reports_dir) / f"{safe_name(name)}-report-{date}.txt"
        if not report.is_file():
            print(f"[SKIP] {name}: report not found ({report.name})"); skipped += 1; continue
        to, cc, invalid = recipients(row)
        if invalid:
            print(f"[WARN] {name}: invalid address(es) ignored: {', '.join(invalid)}")
        if not to:
            print(f"[SKIP] {name}: no valid address in the Email column"); skipped += 1; continue
        msg = build_message(row, report, sender or "devops-automation@example.com", to, cc)
        if dry:
            print(f"[TEST_MODE] {name}: NOT sent | To: {', '.join(to)} | CC: {', '.join(cc) or '-'} | Subject: {msg['Subject']} | attachment: {report.name}")
            sent += 1; continue
        try:
            send(msg, to, cc, server, port, user, password, security)
            print(f"[SENT] {name}: To: {', '.join(to)} | CC: {', '.join(cc) or '-'}"); sent += 1
        except smtplib.SMTPAuthenticationError:
            print(f"[FAIL] {name}: SMTP authentication failed (check SMTP_USERNAME / SMTP_PASSWORD)"); failed += 1
        except (smtplib.SMTPException, OSError) as exc:
            print(f"[FAIL] {name}: {type(exc).__name__}: {exc}"); failed += 1
    print(f"Summary: {'would send' if dry else 'sent'}={sent} skipped={skipped} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
