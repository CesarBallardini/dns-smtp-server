# dns-smtp-server

Authoritative DNS and an SMTP server on one Oracle Cloud **Always Free** VM, provisioned and configured with Ansible from a Docker container. It works the same on Windows, Linux, and macOS: you only need Docker and `make`.

- **DNS**: BIND9, authoritative only, serves `gnandu.com.ar` and `ballardini.com.ar`. Each zone gets NS, MX, SPF, DKIM, and DMARC records automatically, plus whatever you add (for example `katra.ballardini.com.ar CNAME cesarballardini.github.io.`).
- **SMTP + IMAP**: Postfix receives mail for those domains and, per address, either:
  - stores it in a **mailbox on the VM** that you read over **IMAP** (Dovecot, port 993 or 143 with STARTTLS); or
  - **forwards** it to a mailbox you already have elsewhere, with an SRS envelope sender (postsrsd) so SPF still passes there.

  Mailbox accounts and separate send-only accounts can also **send** through authenticated submission on port 587, DKIM-signed by OpenDKIM.

  Reading mail needs nothing from Oracle. *Sending* and *forwarding* need the port-25 exemption described below.

The layout and conventions follow the `infra/` directory of the bluedoter project. Config and secrets never live in this repo: they stay in `~/.dns-smtp-server/` on your machine.

```
                       internet
  53/udp+tcp | 25 | 587 | 143 | 993 | 80 (ACME)
  +----------+----+-----+-----+-----+------------------------------+
  | OCI security list  ->  VM iptables (OCI ruleset + our ports)   |
  |                                                                |
  |  BIND9 ----- zones from ~/.dns-smtp-server/group_vars/all.yml  |
  |                                                                |
  |  Postfix :25 -+- mailbox  -- LMTP -> Dovecot -> Maildir        |
  |               |                          ^                     |
  |               +- alias    -- forward (SRS) -> your other inbox |
  |                                          |                     |
  |  IMAP :993 / :143 --------- Dovecot -----+                     |
  |  Postfix :587 -- Dovecot SASL -- OpenDKIM -> recipients        |
  |                                                                |
  |  Ubuntu 24.04 - VM.Standard.E2.1.Micro - reserved public IP    |
  +----------------------------------------------------------------+
```

- **Configuration reference**: [docs/config.md](docs/config.md) explains every setting and secret file.
- **Everyday commands**: `make help`.

---

## The Oracle Cloud Free Tier

Oracle's free offer has two separate parts, and people often mix them up.

| | **Free Trial** | **Always Free** |
|---|---|---|
| What | US$300 of credits for any service | A fixed set of resources that cost nothing |
| How long | Up to 30 days | For the life of the account |
| When it ends | Paid resources are reclaimed unless you upgrade; the account stays active | Never ends |

This project uses **only Always Free resources**, so it costs nothing after the trial ends.

### What Always Free includes

| Resource | Always Free allowance | This project uses |
|---|---|---|
| AMD compute `VM.Standard.E2.1.Micro` | Up to **2 instances**. Each has 1/8 OCPU (can burst), 1 GB RAM, and up to 50 Mbps internet bandwidth. | 1 instance |
| Arm compute `VM.Standard.A1.Flex` | 1,500 OCPU-hours + 9,000 GB-hours per month, i.e. **2 OCPUs + 12 GB** running full-time on an Always Free tenancy | Not used (optional alternative shape) |
| Block Volume | **200 GB total**, boot and data volumes combined, plus 5 backups | 50 GB boot volume |
| Outbound data transfer | **10 TB per month** | A few MB |
| Virtual Cloud Networks | **2 VCNs** on Free Tier tenancies | 1 |
| Email Delivery (OCI's SMTP relay) | **3,000 emails per month** | Optional, see [relay](docs/config.md#optional-smarthost-relay) |
| Object Storage | 20 GB | Not used |

Things to know before you rely on it:

- **Home region only.** Always Free compute can only be created in the tenancy's *home region*, which you pick at sign-up and cannot change. Set `oci_region` to that region.
- **Idle reclamation.** Oracle may reclaim an idle Always Free instance. It counts as idle when, over 7 days, 95th-percentile CPU is below 20% **and** network utilization is below 20%. Memory below 20% is also a criterion, but only on A1 shapes. A quiet DNS/mail server can look idle. A reclaimed instance is *stopped*, not deleted, and `make vm-start` brings it back. Upgrading to Pay As You Go removes this risk (see below).
- **Capacity.** A1.Flex capacity is often exhausted ("Out of host capacity"). E2.1.Micro is usually available, which is one reason it's the default here.
- **Public IPs.** This project uses a **reserved** public IP, because glue records, MX, and PTR all depend on the address never changing. Reserved IPs are not in the Always Free list. Free Tier tenancies can hold only a small number of them, and they are not known to be billed while attached to an instance, but check before you start: look at *Governance -> Limits, Quotas and Usage -> Networking -> Reserved Public IPs*, and watch *Cost Analysis* after the first day.

### The two email restrictions, and Pay As You Go

These two are why "run a mail server on the free tier" needs a couple of support requests. Neither involves code in this repo.

1. **Outbound port 25 is blocked** for tenancies created after 23 June 2021. Your VM can *receive* mail on 25 and accept submissions on 587, but it cannot *deliver* to other mail servers until Oracle grants an exemption. You request it through a *service limit request* (Console -> Help -> Support -> "Service Limit Increase" -> *Email Delivery / SMTP port 25*).
   - Free-only accounts are commonly asked to **upgrade to Pay As You Go first**.
   - Forwarding (the MX role) needs port 25 no matter what: a relay such as OCI Email Delivery only accepts mail whose *From* is an approved sender, and forwarded mail is from someone else.
2. **Reverse DNS (PTR)** for an Oracle-owned IP can only be set by Oracle support. Big receivers (Gmail, Outlook) distrust mail from an IP without a matching PTR. Open a support request once `mail.<domain>` resolves to the IP (Phase 2).

**Upgrading to Pay As You Go** attaches a payment method, but in Oracle's words, Oracle *"doesn't charge for Always Free resources after you upgrade"*: you only pay for usage above the free limits. Operators commonly report two more effects: the upgrade is what gets the port-25 exemption approved, and upgraded tenancies are not subject to idle reclamation. Oracle's page doesn't say either, so treat them as likely, not guaranteed. Set a budget alert in the Console as a safety net.

Sources: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) - [Oracle Cloud Free Tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm) - [Reverse DNS (PTR)](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/reverse_dns.htm). Figures were checked in September 2026; Oracle changes them from time to time.

---

## Repository layout

```
Makefile                         operator commands (make help)
pyproject.toml, uv.lock          Python 3.14 tooling for the controller (ansible-core, molecule, oci SDK)
docs/config.md                   every setting and secret, explained
ansible/
  Dockerfile, docker-compose.yml the controller image (uv + Python 3.14 + oci-cli + goss)
  inventory.yml.example          -> ~/.dns-smtp-server/inventory.yml
  group_vars/all.yml.example     -> ~/.dns-smtp-server/group_vars/all.yml
  playbooks/
    oci-vm-create.yml            VCN, IGW, route, security list, subnet, VM, reserved IP
    oci-vm-start.yml / -stop.yml start / stop the VM (found by tag)
    oci-vm-destroy.yml           tear down everything except the reserved IP
    discover.yml                 find the VM by tag (imported by host-prep / verify)
    host-prep.yml                configure the VM (roles below)
    verify.yml                   goss on the VM + checks from the internet
    dns-check.yml                query every configured name (VM + public resolver)
    info.yml                     VM address, SSH, IMAP/SMTP client settings
    templates/dnssmtp-derived.yml.j2   zones / DKIM / aliases derived from your config
  roles/
    os_hardening                 ops user, sshd lockdown, fail2ban, firewall ports, swap
    opendkim                     DKIM signing milter
    postfix                      MX forwarding, SRS, submission + Dovecot SASL, TLS
    bind9                        authoritative zones with idempotent serials
    alpine                       text-mode mail client on the VM, over SSH
    */molecule/default/          per-role tests (Docker) with goss specs
  tasks/                         shared goss install / run tasks
  tests/                         goss specs: controller image, live host
```

---

## Runbook

All commands run from the repo root in Git Bash, WSL, Linux, or macOS.

### Phase 0: one-time setup

1. **Docker Desktop** (Windows/macOS) or Docker Engine (Linux), and GNU `make`.
2. **Oracle Cloud account**. Pick the home region carefully (see above).
3. **SSH key** at `~/.ssh/id_ed25519` (`ssh-keygen -t ed25519`).
4. **OCI API key + CLI config** at `~/.oci/config`. Create an API key under *Profile -> My profile -> API keys -> Add API key*, save the private key under `~/.oci/`, and paste the configuration snippet the Console shows into `~/.oci/config`, pointing `key_file` at `/root/.oci/<key>.pem` (the path inside the controller).
5. **Build and self-test the controller**:
   ```bash
   make ansible-build
   make ansible-selftest
   ```
6. **Create your config directory** (outside the repo):
   ```bash
   mkdir -p ~/.dns-smtp-server/group_vars
   cp ansible/inventory.yml.example      ~/.dns-smtp-server/inventory.yml
   cp ansible/group_vars/all.yml.example ~/.dns-smtp-server/group_vars/all.yml
   $EDITOR ~/.dns-smtp-server/group_vars/all.yml
   ```
   Fill in at least `oci_compartment_id`, `oci_availability_domain`, and `dnssmtp_admin_email`. The domains and the `katra` CNAME are already set. [docs/config.md](docs/config.md) explains every line; `make shell` then `oci iam availability-domain list` shows your AD names.
7. **Generate the secrets.** They are written to `~/.dns-smtp-server/` with mode 600, and the targets refuse to overwrite existing files:
   ```bash
   make dkim-keygen DOMAIN=gnandu.com.ar
   make dkim-keygen DOMAIN=ballardini.com.ar
   make smtp-password LOGIN=cesar@ballardini.com.ar     # one per mailbox
   make smtp-password LOGIN=noreply@ballardini.com.ar   # one per send-only app account
   ```
   Then in `all.yml` list each mailbox under `postfix_mailboxes`, each forwarding address under `postfix_virtual_aliases`, and each app account under `postfix_submission_users`. Every served domain needs `postmaster@` and `abuse@` to exist as one or the other; by default they forward to `dnssmtp_admin_email`.

   **Back up `~/.dns-smtp-server/`**: the DKIM keys and passwords exist nowhere else.

### Phase 1: create the VM

```bash
make vm-create
```

This prints the **reserved public IP**. It stays yours across `vm-destroy` / `vm-create` cycles.

### Phase 2: registrar, PTR, and port 25 (outside this repo)

For `.com.ar` domains the registry is **NIC Argentina** (nic.ar), where the change is a domain *delegation*.

1. **Glue / host record**: `ns1.gnandu.com.ar -> <reserved IP>`. A nameserver named inside the domain being delegated needs its IP registered as glue.
2. **Delegation**: set the nameservers of **both** `gnandu.com.ar` and `ballardini.com.ar` to `ns1.gnandu.com.ar`.
   - Many registries require **two** nameservers. The robust answer is a free secondary DNS service, for example Hurricane Electric's `ns2.he.net`-`ns5.he.net`. Put its names in `dnssmtp_extra_nameservers` and its transfer IP in `bind9_secondaries`, re-run `make vm-prep`, then list both at the registrar.
   - Serving both names from one IP works, but with no redundancy.
3. **PTR**: once `dig mail.gnandu.com.ar` returns the IP from a public resolver, open an OCI support request asking for PTR `<IP> -> mail.gnandu.com.ar`.
4. **Port 25 exemption**: open a service limit request (see *The two email restrictions* above). DNS, inbound mail, and **reading it over IMAP** all work without it. Forwarding aliases and outbound sending don't.

### Phase 3: configure the VM

```bash
make vm-prep
```

This applies `os_hardening -> opendkim -> postfix -> bind9`. It's idempotent, so re-run it after **any** change to `all.yml`: new records, aliases, submission users, secondaries.

### Phase 4: real TLS certificate

Once `mail.gnandu.com.ar` resolves publicly (after Phase 2), set `postfix_letsencrypt_enabled: true` in `all.yml` and run `make vm-prep` again. certbot gets the certificate over HTTP-01 on port 80, renews it automatically, and reloads Postfix and Dovecot after each renewal. Until then both use the self-signed snakeoil certificate, so mail clients will warn about it.

#### Setting up a mail client

| Setting | Value |
|---|---|
| Incoming | IMAP, `mail.gnandu.com.ar`, port **993**, SSL/TLS (or 143 with STARTTLS) |
| Outgoing | SMTP, `mail.gnandu.com.ar`, port **587**, STARTTLS |
| Username | the full address, e.g. `cesar@ballardini.com.ar` |
| Password | the contents of `~/.dns-smtp-server/smtp-users/<address>` |

Thunderbird, Outlook, and the iOS/Android mail apps all work with this. Sending requires the port-25 exemption; receiving does not.

### Phase 5: verify

```bash
make vm-verify
```

- **On the VM**: goss checks services, listening ports, configs, the firewall order, every zone, and every mailbox (known to both Postfix and Dovecot, IMAP requiring TLS, no PAM authentication).
- **From your machine**, against the public IP:
  - **must pass**: authoritative answers, MX, DKIM, no open resolver, STARTTLS on 587, IMAPS on 993;
  - **reported only**: registrar delegation, PTR, and port 25 reachability (many home ISPs block outbound 25, so check from another network before worrying).

For a full deliverability check, send a message from a submission account to the address shown on [mail-tester.com](https://www.mail-tester.com/) and look at the SPF, DKIM, DMARC, and PTR results.

#### Manual checks from a Windows laptop

PowerShell's `Resolve-DnsName` is built in. `-DnsOnly` skips hosts files and NetBIOS, and `-Server` queries the VM directly, so this works before the registrar delegation exists.

```powershell
$ip = "<reserved IP from make vm-create>"

# Authoritative answers from the VM itself
Resolve-DnsName -Server $ip -Name gnandu.com.ar              -Type SOA   -DnsOnly
Resolve-DnsName -Server $ip -Name ballardini.com.ar          -Type NS    -DnsOnly
Resolve-DnsName -Server $ip -Name gnandu.com.ar              -Type MX    -DnsOnly
Resolve-DnsName -Server $ip -Name ballardini.com.ar          -Type TXT   -DnsOnly   # SPF
Resolve-DnsName -Server $ip -Name _dmarc.ballardini.com.ar   -Type TXT   -DnsOnly   # DMARC
Resolve-DnsName -Server $ip -Name s1._domainkey.gnandu.com.ar -Type TXT  -DnsOnly   # DKIM key
Resolve-DnsName -Server $ip -Name katra.ballardini.com.ar    -Type CNAME -DnsOnly
Resolve-DnsName -Server $ip -Name gnandu.com.ar -Type SOA -DnsOnly -TcpOnly        # DNS over TCP
Resolve-DnsName -Server $ip -Name example.com   -Type A   -DnsOnly                 # must FAIL: no recursion

# After the registrar delegation: what the rest of the internet sees
Resolve-DnsName -Server 1.1.1.1 -Name gnandu.com.ar -Type NS
Resolve-DnsName -Server 1.1.1.1 -Name katra.ballardini.com.ar

# Mail ports (many home ISPs block outbound 25; the others should connect)
Test-NetConnection $ip -Port 587
Test-NetConnection $ip -Port 993
Test-NetConnection $ip -Port 25
```

To prove a mailbox really works, point a mail client at it (settings above), or from PowerShell read the INBOX over IMAPS:

```powershell
# -SkipCertificateCheck equivalent: trust anything, needed before Let's Encrypt
$box = "cesar@ballardini.com.ar"
$pw  = Get-Content "$HOME\.dns-smtp-server\smtp-users\$box"
$tcp = [Net.Sockets.TcpClient]::new($ip, 993)
$ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient("mail.gnandu.com.ar")
$rw = [IO.StreamWriter]::new($ssl); $rd = [IO.StreamReader]::new($ssl)
$rd.ReadLine()                                   # * OK ... ready
$rw.WriteLine("a LOGIN $box $pw"); $rw.Flush(); $rd.ReadLine()
$rw.WriteLine("b SELECT INBOX");   $rw.Flush(); while (($l = $rd.ReadLine()) -notmatch '^b ') { $l }
$rw.WriteLine("c LOGOUT"); $rw.Flush(); $ssl.Dispose(); $tcp.Close()
```

`nslookup -type=soa gnandu.com.ar <ip>` does the same from `cmd.exe`. For `dig`, which shows the `aa` (authoritative) flag, run `make shell` and then `dig @<ip> gnandu.com.ar SOA +norec`.

### Day-2 operations

| Task | How |
|---|---|
| See the VM's IP + mail client settings | `make vm-info` |
| See the mail logins **with passwords** | `make show-credentials` (reads the local files; the VM only stores hashes) |
| Check every configured DNS name | `make dns-check` -- queries each record on the VM *and* through a public resolver, so you can tell "BIND isn't serving it" from "the delegation hasn't propagated" |
| Add a DNS record | Add it to the domain's `records` in `all.yml`, then `make vm-prep`. The SOA serial bumps only when records change. |
| Add a mailbox | `make smtp-password LOGIN=<address>`, add it to `postfix_mailboxes`, then `make vm-prep`. The Maildir is created on the first delivery. |
| Catch every address in a domain | Add `"@domain": "catchall@domain"` to `postfix_virtual_aliases` (with a mailbox of that name). Mailboxes in the domain are exempted automatically and keep their own mail. |
| Read mail on the VM itself | `ssh ops@<ip>` then `alpine` -- it opens the first mailbox over IMAP on loopback and asks for the password. |
| Add a forwarding alias | Add to `postfix_virtual_aliases`, then `make vm-prep`. |
| Add an app that sends mail | `make smtp-password LOGIN=...`, add it to `postfix_submission_users`, then `make vm-prep`. |
| Change a password | Delete the file in `~/.dns-smtp-server/smtp-users/`, run `make smtp-password LOGIN=...` again, then `make vm-prep`. |
| Rotate a DKIM key | `make dkim-keygen DOMAIN=... SELECTOR=s2`, set `dkim_selector: s2`, then `make vm-prep`. The new public key and new signing go live together. |
| Stop / start | `make vm-stop` / `make vm-start`. While stopped, senders queue and retry for days. |
| Rebuild the VM from scratch | `make vm-destroy && make vm-create && make vm-prep`. Same IP and same DKIM keys, so nothing changes at the registrar, and the Let's Encrypt certificate is issued again. **Stored mail is destroyed**: the Maildirs live only on the VM's boot volume. Copy them off first (below) or keep a client with a local copy. |
| Back up the mailboxes | `rsync -az --rsync-path='sudo rsync' ops@<ip>:/var/mail/vhosts/ ./mail-backup/` (or `scp -r`). Nothing in this repo does it for you. |

### Tests

```bash
make lint          # yamllint + ansible-lint (production profile)
make syntax        # --syntax-check every playbook
make test-roles    # molecule: converge, idempotence, goss verify, for all four roles
make test-role ROLE=postfix
```

The postfix scenario runs opendkim and postfix together and tests real SMTP and IMAP behaviour:
- AUTH is only offered after STARTTLS, and a wrong password is rejected;
- a user cannot send as someone else's address;
- submitted mail is DKIM-signed;
- port 25 is not an open relay, and unknown recipients are rejected;
- forwarded mail carries an SRS sender and no DKIM signature from us;
- mail sent to a mailbox address is delivered and can be read over IMAP;
- IMAP refuses a send-only account, and refuses any login before TLS.

## Not included (possible follow-ups)

- **DNSSEC**: a VM rebuild would regenerate signing keys and break the DS record at the registrar unless the keys are persisted like the DKIM keys.
- **Spam filtering** (rspamd) beyond Postfix's built-in restrictions, **Sieve** rules, server-side **quotas**, webmail, POP3, and **IPv6**.
- **Automated mailbox backups.** Configuration is in git plus `~/.dns-smtp-server/`, but the Maildirs under `/var/mail/vhosts/` on the VM are not backed up by anything here. The 50 GB boot volume is the only copy.
