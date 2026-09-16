#!/usr/bin/env python3
"""SMTP + IMAP behaviour checks for the postfix molecule scenario.

Runs inside the test container and exits non-zero on the first
failed expectation. Each check prints one "ok"/"FAIL" line for goss output.
"""

import glob
import imaplib
import smtplib
import socket
import ssl
import subprocess
import sys
import time

HOST = "127.0.0.1"
# Port-25 checks must come from OUTSIDE mynetworks (127.0.0.0/8), or Postfix
# rightly permits relaying and the open-relay test proves nothing. The
# container's own routable address stands in for a remote sender.
EXTERNAL = socket.gethostbyname(socket.gethostname())
USER = "app@example.test"
PASSWORD = "molecule-test-password-0123456789"
BOX_USER = "box@example.test"
BOX_PASSWORD = "molecule-mailbox-password-0123456789"
MAILBOX = "/var/mail/root"
TLS = ssl._create_unverified_context()  # snakeoil certificate in the test


def check(name, condition):
    print(f"{'ok' if condition else 'FAIL'}: {name}")
    if not condition:
        sys.exit(1)


def submission():
    client = smtplib.SMTP(HOST, 587, timeout=30)
    client.ehlo("client.example.org")
    return client


def wait_for_mailbox(marker, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for path in glob.glob(MAILBOX):
            with open(path, encoding="utf-8", errors="replace") as mailbox:
                content = mailbox.read()
            if marker in content:
                return content[content.rfind("From ", 0, content.find(marker)):]
        subprocess.run(["postqueue", "-f"], check=False)
        time.sleep(2)
    return ""


# 587 refuses AUTH before STARTTLS.
client = submission()
check("587 does not offer AUTH before STARTTLS", not client.has_extn("auth"))
client.starttls(context=TLS)
client.ehlo("client.example.org")
check("587 offers AUTH after STARTTLS", client.has_extn("auth"))

try:
    client.login(USER, "wrong-password-0000000000")
    check("wrong password is rejected", False)
except smtplib.SMTPAuthenticationError:
    check("wrong password is rejected", True)
client.quit()

# Authenticated user may not send as an address it doesn't own.
client = submission()
client.starttls(context=TLS)
client.ehlo("client.example.org")
client.login(USER, PASSWORD)
check("login succeeds with the right password", True)
try:
    client.sendmail("ceo@example.test", ["info@example.test"], "Subject: spoof\r\n\r\nx\r\n")
    check("sender login mismatch is rejected", False)
except (smtplib.SMTPRecipientsRefused, smtplib.SMTPSenderRefused):
    check("sender login mismatch is rejected", True)

# Authenticated mail from an owned address is accepted and DKIM-signed.
marker = f"dkim-check-{time.time_ns()}"
client.sendmail(
    "noreply@example.test",
    ["info@example.test"],
    f"From: noreply@example.test\r\nTo: info@example.test\r\nSubject: {marker}\r\n\r\nbody\r\n",
)
client.quit()
message = wait_for_mailbox(marker)
check("submitted mail is delivered via the alias", bool(message))
check("submitted mail carries a DKIM signature for example.test",
      "DKIM-Signature:" in message and "d=example.test" in message and "s=s1" in message)

# Port 25 is not an open relay.
client = smtplib.SMTP(EXTERNAL, 25, timeout=30)
client.ehlo("client.example.org")
code, _ = client.mail("")
code, _ = client.rcpt("someone@gmail.com")
check("port 25 refuses to relay to foreign domains", code >= 500)
client.rset()

# Unknown recipients in a served domain are rejected at RCPT (no backscatter).
client.mail("")
code, _ = client.rcpt("nobody@example.test")
check("unknown recipient in served domain is rejected", code >= 500)
client.quit()

# Inbound mail from a foreign sender is forwarded with an SRS envelope.
marker = f"srs-check-{time.time_ns()}"
client = smtplib.SMTP(EXTERNAL, 25, timeout=30)
client.ehlo("client.example.org")
client.sendmail(
    "someone@gmail.com",
    ["postmaster@example.test"],
    f"From: someone@gmail.com\r\nTo: postmaster@example.test\r\nSubject: {marker}\r\n\r\nbody\r\n",
)
client.quit()
message = wait_for_mailbox(marker)
check("inbound mail is forwarded", bool(message))
check("forwarded mail has an SRS envelope sender", "Return-Path: <SRS0=" in message)
check("forwarded mail is NOT DKIM-signed by us", "d=example.test" not in message)


# ------------------------------------------------------------------ IMAP
def imap_search(marker, timeout=90):
    """Log in over IMAPS and wait for a message with this subject."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        imap = imaplib.IMAP4_SSL(HOST, 993, ssl_context=TLS)
        try:
            imap.login(BOX_USER, BOX_PASSWORD)
            imap.select("INBOX")
            _, data = imap.search(None, "SUBJECT", f'"{marker}"')
            if data and data[0].split():
                return True
        finally:
            try:
                imap.logout()
            except OSError:
                pass
        time.sleep(2)
    return False


# Mail addressed to a mailbox is stored here, not forwarded.
marker = f"imap-check-{time.time_ns()}"
client = smtplib.SMTP(EXTERNAL, 25, timeout=30)
client.ehlo("client.example.org")
client.sendmail(
    "someone@gmail.com",
    [BOX_USER],
    f"From: someone@gmail.com\r\nTo: {BOX_USER}\r\nSubject: {marker}\r\n\r\nbody\r\n",
)
client.quit()
check("inbound mail is readable in the IMAP mailbox", imap_search(marker))


# ------------------------------------------------------- catch-all domain
def deliver(sender, recipient, marker):
    client = smtplib.SMTP(EXTERNAL, 25, timeout=30)
    client.ehlo("client.example.org")
    client.sendmail(
        sender, [recipient],
        f"From: {sender}\r\nTo: {recipient}\r\nSubject: {marker}\r\n\r\nbody\r\n")
    client.quit()


def in_mailbox(user, password, marker, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        imap = imaplib.IMAP4_SSL(HOST, 993, ssl_context=TLS)
        try:
            imap.login(user, password)
            imap.select("INBOX")
            _, data = imap.search(None, "SUBJECT", f'"{marker}"')
            if data and data[0].split():
                return True
        finally:
            try:
                imap.logout()
            except OSError:
                pass
        time.sleep(2)
    return False


# Any unlisted address in the catch-all domain lands in the catch-all mailbox.
marker = f"catchall-{time.time_ns()}"
deliver("someone@gmail.com", "anything-goes@example2.test", marker)
check("catch-all domain accepts an unlisted address",
      in_mailbox("catchall@example2.test", "molecule-catchall-password-0123456789", marker))

# ...but a mailbox inside that domain still gets its own mail.
marker = f"named-{time.time_ns()}"
deliver("someone@gmail.com", "named@example2.test", marker)
check("a mailbox in the catch-all domain keeps its own mail",
      in_mailbox("named@example2.test", "molecule-named-password-0123456789", marker))
check("that mail did NOT go to the catch-all instead",
      not in_mailbox("catchall@example2.test", "molecule-catchall-password-0123456789",
                     marker, timeout=10))

# A send-only account has no userdb entry, so it cannot open a mailbox.
imap = imaplib.IMAP4_SSL(HOST, 993, ssl_context=TLS)
try:
    imap.login(USER, PASSWORD)
    check("IMAP refuses a send-only account", False)
except imaplib.IMAP4.error:
    check("IMAP refuses a send-only account", True)
finally:
    try:
        imap.logout()
    except (OSError, imaplib.IMAP4.error):
        pass

# Port 143 offers STARTTLS and works once encrypted.
#
# Whether it REFUSES a cleartext login cannot be tested from here: Dovecot
# treats a connection as already secure when the peer address is the machine
# itself (loopback, or its own IP), so any same-host probe is exempt from
# disable_plaintext_auth. The goss spec asserts the setting instead, and
# playbooks/verify.yml proves the behaviour from the controller, which is a
# genuinely remote client.
imap = imaplib.IMAP4(EXTERNAL, 143)
check("IMAP on 143 advertises STARTTLS", "STARTTLS" in str(imap.capabilities))
imap.starttls(ssl_context=TLS)
imap.login(BOX_USER, BOX_PASSWORD)
check("IMAP on 143 accepts login after STARTTLS", True)
imap.logout()
