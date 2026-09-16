# Configuration reference

This page explains every setting that controls the deployment: where it lives, what it does, its default, and when you would change it.

**No secret ever goes in this repository.** Values are split in three:

1. **Identifiers and choices** go in `~/.dns-smtp-server/group_vars/all.yml`, which you copy from [`ansible/group_vars/all.yml.example`](../ansible/group_vars/all.yml.example).
2. **Secret values** (passwords, DKIM private keys, relay credentials) are **separate chmod-600 files** under `~/.dns-smtp-server/`. `all.yml` only references them with `lookup('file', ...)`.
3. **Role defaults** (`ansible/roles/*/defaults/main.yml`) hold sensible values you rarely override.

On your machine the tree is `~/.dns-smtp-server/`. Inside the controller container the same directory is mounted **read-only** at `/etc/dns-smtp-server/`, which is why paths in `all.yml` start with `/etc/dns-smtp-server/`.

- [Files on your machine](#files-on-your-machine)
- [OCI: the VM and its network](#oci-the-vm-and-its-network)
- [DNS: zones](#dns-zones)
- [Mail: mailboxes, forwarding, and submission](#mail-mailboxes-forwarding-and-submission)
- [TLS](#tls)
- [Optional smarthost relay](#optional-smarthost-relay)
- [Role defaults](#role-defaults)
- [Controller container settings](#controller-container-settings)
- [What gets generated on the VM](#what-gets-generated-on-the-vm)
- [Commands](#commands)

---

## Files on your machine

| Path | Secret? | Created by | Purpose |
|---|---|---|---|
| `~/.dns-smtp-server/inventory.yml` | no | copy of `ansible/inventory.yml.example` | Tells Ansible to run the OCI API calls on `localhost`. The VM itself is discovered by tag at run time. |
| `~/.dns-smtp-server/group_vars/all.yml` | no, but environment-specific | copy of `ansible/group_vars/all.yml.example` | All the settings below. |
| `~/.dns-smtp-server/dkim/<domain>.<selector>.key` | **yes** | `make dkim-keygen DOMAIN=<domain> [SELECTOR=s1]` | RSA-2048 DKIM private key. Its public half is published in DNS automatically. Kept off the VM's lifecycle, so a rebuild keeps the same DNS record. |
| `~/.dns-smtp-server/smtp-users/<login>` | **yes** | `make smtp-password LOGIN=<login>` | Password of one account -- a mailbox (IMAP + submission) or a send-only app account: one line, 40 random base64 chars. Stored **hashed** (SHA512-CRYPT) on the VM. |
| `~/.dns-smtp-server/relay_username`, `relay_password` | **yes** | you, only if you use a relay | Smarthost SMTP credentials (see [relay](#optional-smarthost-relay)). |
| `~/.ssh/id_ed25519` + `.pub` | **yes** (private half) | `ssh-keygen -t ed25519` | The public key is injected into the VM at creation. Ansible logs in with the private key. |
| `~/.oci/config` + API key `.pem` | **yes** | OCI Console -> *My profile -> API keys* | Authenticates the `oracle.oci` modules and `oci` CLI. Inside the controller `key_file` must read `/root/.oci/<file>.pem`. |

Keep the directory private (`chmod 700 ~/.dns-smtp-server`) and **back it up**: the DKIM keys and passwords exist nowhere else. Rotating them is possible but disruptive.

---

## OCI: the VM and its network

Read by `oci-vm-create`, `oci-vm-start`, `oci-vm-stop`, `oci-vm-destroy`, and the discovery step of `host-prep` / `verify`.

### Required

| Variable | Example | What it is / how to find it |
|---|---|---|
| `oci_compartment_id` | `ocid1.compartment.oc1..aaaa...` | Compartment that holds every resource. `oci iam compartment list --all` (the tenancy OCID also works as the root compartment). The create playbook refuses the `XXXX` placeholder. |
| `oci_region` | `us-ashburn-1` | Must be the tenancy's **home region**: Always Free compute exists only there. It must match `region` in `~/.oci/config`. |
| `oci_availability_domain` | `Uocm:US-ASHBURN-AD-1` | `oci iam availability-domain list`. The 4-character prefix is specific to your tenancy. If creation fails with *Out of host capacity*, try another AD. |
| `dnssmtp_admin_email` | `you@example.net` | See [Mail](#mail-mailboxes-forwarding-and-submission). Required by `host-prep`. |

### Access

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_ssh_pubkey_path` | `/root/.ssh/id_ed25519.pub` | Container path of the public key put in the VM's `authorized_keys` (your `~/.ssh` is copied to `/root/.ssh`). |
| `dnssmtp_ssh_ingress_cidr` | `0.0.0.0/0` | Who may reach port 22, enforced by the OCI security list. Narrow it to `<your-ip>/32` if your IP is stable. With a dynamic home IP, key-only SSH plus fail2ban is a reasonable trade-off. |

### Compute

| Variable | Default | Meaning |
|---|---|---|
| `oci_shape` | `VM.Standard.E2.1.Micro` | Always Free AMD micro VM (1/8 OCPU, 1 GB). BIND + Postfix + OpenDKIM + Dovecot use about 300 MB. `VM.Standard.A1.Flex` (Arm) also works. Changing architecture needs destroy + create. |
| `oci_shape_ocpus` | `1` | Flex shapes only (ignored for E2.1.Micro). |
| `oci_shape_memory_gb` | `6` | Flex shapes only. |
| `oci_boot_volume_size_gb` | `50` | Boot volume size. Counts against the 200 GB Always Free block storage. 50 GB is OCI's minimum. |
| `oci_image_id` | `null` | `null` picks the newest *Canonical Ubuntu* image of `oci_image_os_version` compatible with the shape. Pin an OCID to freeze the image. |
| `oci_image_os_version` | `24.04` | Ubuntu release for auto-resolution. The roles are tested on 24.04. |

### Network

| Variable | Default | Meaning |
|---|---|---|
| `oci_vcn_cidr` | `10.0.0.0/16` | VCN address space. Private, never visible outside. |
| `oci_subnet_cidr` | `10.0.0.0/24` | Public subnet inside the VCN. |

The security list (ingress) is fixed in `oci-vm-create.yml`:

- 22/tcp from `dnssmtp_ssh_ingress_cidr`;
- 53/udp and 53/tcp (DNS), 25/tcp (inbound mail), 80/tcp (ACME only),
  587/tcp (submission), 143/tcp and 993/tcp (IMAP) from anywhere;
- ICMP type 3 code 4 (path MTU discovery), always;
- ICMP type 8 (echo request, i.e. `ping`) when `dnssmtp_allow_ping` is true.

Egress is open.

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_allow_ping` | `true` | Answer `ping`. Set to `false` and re-run `make vm-create` to drop the rule; the host stays reachable on its service ports, it just stops replying to echo requests. |

### Naming and discovery

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_env_tag` | `prod` | **Discovery key.** Every resource gets the freeform tag `dnssmtp: <env_tag>`, and start/stop/destroy/host-prep/verify find resources by it, so there is no state file. 1-8 lowercase letters/digits, because it is also part of the OCI DNS labels `dnssmtp<env_tag>`. Use a different value to run a second, independent environment in the same compartment. |
| `dnssmtp_vcn_name` | `dnssmtp-{{ dnssmtp_env_tag }}-vcn` | Display name. Creation reuses resources with the same name. |
| `dnssmtp_subnet_name` | `dnssmtp-{{ dnssmtp_env_tag }}-public` | (same) |
| `dnssmtp_ig_name` | `dnssmtp-{{ dnssmtp_env_tag }}-igw` | (same) |
| `dnssmtp_seclist_name` | `dnssmtp-{{ dnssmtp_env_tag }}-seclist` | (same) |
| `dnssmtp_instance_name` | `dnssmtp-{{ dnssmtp_env_tag }}` | (same) |
| `dnssmtp_public_ip_name` | `dnssmtp-{{ dnssmtp_env_tag }}-ip` | Display name of the **reserved public IP**. It is looked up by this name, re-attached on re-create, and **never deleted** by `vm-destroy`. |
| `dnssmtp_freeform_tags` | `{dnssmtp: <env_tag>, managed_by: ansible}` | Tags applied to everything. Don't remove the `dnssmtp` key. |

---

## DNS: zones

Read by `host-prep` (which turns them into `bind9_zones`) and `verify`.

### `dnssmtp_domains`

The list of zones served authoritatively. For **each** entry the server publishes:

| Record | Value |
|---|---|
| `@ NS` | `dnssmtp_ns_hostname.` plus every `dnssmtp_extra_nameservers` entry |
| `@ SOA` | primary NS, `hostmaster.<domain>.`, serial managed automatically |
| `@ MX 10` | `dnssmtp_mail_hostname.` |
| `@ TXT` | `dnssmtp_spf` |
| `_dmarc TXT` | `v=DMARC1; p=<dnssmtp_dmarc_policy>; rua=mailto:postmaster@<domain>` |
| `<dkim_selector>._domainkey TXT` | `v=DKIM1; k=rsa; p=<public key derived from the private key file>` |
| `ns1` / `mail` `A` | the reserved public IP. Added only to the zone that contains those host names. |
| everything in `records` | as written |

Entry fields:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Zone apex, e.g. `ballardini.com.ar`. |
| `dkim_selector` | yes | DKIM selector. The key file must be `~/.dns-smtp-server/dkim/<name>.<selector>.key`. Use a new selector (`s2`, ...) to rotate. |
| `records` | no | Extra records: `{ name, type, value, ttl? }`.<br>* `name` is relative to the zone (`@` = apex, `katra` = `katra.<zone>`).<br>* `type` is any record type BIND accepts (`A`, `AAAA`, `CNAME`, `TXT`, `MX`, `SRV`, `CAA`, ...).<br>* `value` is the record data exactly as in a zone file. A **host name that is not relative must end with a dot**. TXT values are written unquoted; quoting and 255-byte splitting are automatic.<br>* `ttl` is optional seconds. |

The configured example:

```yaml
dnssmtp_domains:
  - name: "gnandu.com.ar"
    dkim_selector: "s1"
    records: []
  - name: "ballardini.com.ar"
    dkim_selector: "s1"
    records:
      - { name: "katra", type: "CNAME", value: "cesarballardini.github.io." }
```

`katra.ballardini.com.ar` is a CNAME to GitHub Pages. For the site to answer on that name, the GitHub repository publishing `cesarballardini.github.io` must also have `katra.ballardini.com.ar` as its *custom domain* (Settings -> Pages, which writes a `CNAME` file). A CNAME can't coexist with other records of the same name, so don't add anything else under `katra`.

### Host names and extra nameservers

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_primary_domain` | first entry of `dnssmtp_domains` | The domain that owns the server's host names. |
| `dnssmtp_ns_hostname` | `ns1.<primary domain>` | Name of this nameserver. Register it as **glue** (host -> IP) at the registrar. |
| `dnssmtp_mail_hostname` | `mail.<primary domain>` | Name of the mail server: MX target, Postfix `myhostname`, TLS certificate name, and the PTR you request from Oracle. |
| `dnssmtp_extra_nameservers` | `[]` | Additional NS for every zone, fully qualified with the trailing dot, e.g. `["ns2.he.net.", "ns3.he.net."]`. Use it when a free secondary DNS service transfers your zones. |
| `bind9_secondaries` | `[]` | IPv4 addresses of those secondaries. They may AXFR the zones and receive NOTIFY on every change. Everyone else is refused transfers. |

### Record policy

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_dns_ttl` | `3600` | Default TTL for every zone. Lower it (e.g. 300) a day before a planned IP or record change. |
| `dnssmtp_spf` | `v=spf1 mx -all` | SPF for every domain: only the MX host may send. If you add a relay, include it, e.g. `v=spf1 mx include:<relay-spf-domain> -all`. |
| `dnssmtp_dmarc_policy` | `none` | DMARC `p=`. Start with `none` and read the aggregate reports sent to `postmaster@<domain>`. Move to `quarantine`, then `reject`, once only your own mail shows up aligned. |
| `dnssmtp_dkim_key_dir` | `/etc/dns-smtp-server/dkim` | Container path of the DKIM key directory. Leave as is. |
| `dnssmtp_reverse_networks` | `[]` | `/24` prefixes (e.g. `["143.47.121"]`) to serve reverse (PTR) zones for. Each becomes a `<3rd>.<2nd>.<1st>.in-addr.arpa` zone holding a PTR for **every A record** pointing into it, including `ns1`/`mail` and your own extra records. Read the warning below before enabling it. |

**A PTR only works if the owner of the address block delegates it.** Reverse
DNS for an OCI address such as `143.47.121.175` lives in a zone Oracle
controls, because Oracle owns the addresses. Serving that zone here is
harmless but inert: no resolver will ask this server unless Oracle delegates
`121.47.143.in-addr.arpa` (or an RFC 2317 slice) to it. For an OCI IP the
working route is a support request, after which Oracle publishes the PTR
itself -- see the README. `dnssmtp_reverse_networks` is for the case where a
block genuinely is delegated to you.

An IP also has only **one** useful PTR. If several A records point at the
same address, this generates several PTRs, which is legal but confuses mail
receivers; ask for the PTR that matches `dnssmtp_mail_hostname`.

### How serials work

A zone is stored as two files on the VM:

- `db.<zone>.records` holds NS + records;
- `db.<zone>` holds the SOA and an `$INCLUDE` of the records file.

The SOA serial becomes the current Unix time **only when the records file changed**. Re-running `vm-prep` with no changes leaves the serial alone, and secondaries are notified only of real edits. `named-checkconf -z` validates every zone before BIND reloads, so a typo fails the play instead of breaking DNS.

---

## Mail: mailboxes, forwarding, and submission

Read by the `postfix` and `opendkim` roles through `host-prep`.

### The model

Every address in a served domain is one of three things, and anything else is rejected during the SMTP conversation (no backscatter):

| Kind | Configured in | What happens to the mail | Needs port 25 out? |
|---|---|---|---|
| **Mailbox** | `postfix_mailboxes` | Postfix hands it to Dovecot over LMTP, which stores it in `/var/mail/vhosts/<domain>/<user>/Maildir`. You read it over IMAP. | no |
| **Forwarding alias** | `postfix_virtual_aliases` | Passed on to an address elsewhere, with an SRS envelope sender (`SRS0=...@<primary domain>`) so the destination's SPF check passes. Not DKIM-signed by us; the original signature travels untouched. | **yes** |
| **Send-only account** | `postfix_submission_users` | Nothing inbound: the address exists only to authenticate on port 587. | **yes**, to send |

Postfix lists the domains as *virtual mailbox domains* and consults the alias map first, which is what lets mailboxes and forwarding coexist in one domain.

- **Submission (587)**: STARTTLS and login are mandatory, and each login may only use its own sender addresses (`reject_sender_login_mismatch`). That mail is DKIM-signed.
- **IMAP (993 implicit TLS, 143 STARTTLS)**: only accounts with a mailbox. Dovecot authenticates against its own passwd-file; **system accounts and PAM are not used**, so an IMAP password is never a shell password. A send-only account has no userdb entry, so its IMAP login fails.

### Variables

| Variable | Default | Meaning |
|---|---|---|
| `dnssmtp_admin_email` | -- (required) | External address that receives `postmaster@`, `abuse@`, and `hostmaster@` for every served domain (unless that address is a mailbox), plus local root mail (cron, certbot). Must be **outside** the served domains, or mail would loop. |
| `postfix_mailboxes` | `[]` | Mailboxes on this host: `[{address, password, senders?}]`. |
| `postfix_virtual_aliases` | `{}` | Forwarding: `"address": "destination"` or `["dest1", "dest2"]`. An explicit entry overrides the automatic `postmaster@`/`abuse@`/`hostmaster@` ones. An address with a mailbox must **not** appear here (the role fails if it does). |
| `"@domain"` entry | -- | A **catch-all**: every address in that domain that isn't listed explicitly goes to the target. Mailboxes in the domain are exempted automatically (mapped to themselves), so they keep their own mail, and the role stops generating `postmaster@`/`abuse@`/`hostmaster@` forwards for that domain because the catch-all already delivers them. A catch-all accepts *any* address, so it collects spam: point it at a mailbox you actually empty. |
| `postfix_submission_users` | `[]` | Send-only accounts: `[{username, password, senders}]`. |

```yaml
postfix_mailboxes:
  - address: "cesar@ballardini.com.ar"
    password: "{{ lookup('file', '/etc/dns-smtp-server/smtp-users/cesar@ballardini.com.ar') | trim }}"
    senders: ["cesar@ballardini.com.ar"]      # optional, defaults to [address]

postfix_virtual_aliases:
  "info@gnandu.com.ar": ["you@example.net", "partner@example.org"]

postfix_submission_users:
  - username: "noreply@ballardini.com.ar"
    password: "{{ lookup('file', '/etc/dns-smtp-server/smtp-users/noreply@ballardini.com.ar') | trim }}"
    senders: ["noreply@ballardini.com.ar"]
```

Account fields (both lists):

| Field | Meaning |
|---|---|
| `address` / `username` | The full e-mail address, which is also the IMAP/SMTP login (case-insensitive). |
| `password` | Always a `lookup('file', ...)` of the file created by `make smtp-password`. At least 16 characters. The VM stores only a SHA512-CRYPT hash, salted from the username so re-runs are idempotent. |
| `senders` | Envelope/From addresses this login may use when sending. Defaults to the mailbox address; required for send-only accounts. |

Mail client settings: IMAP `dnssmtp_mail_hostname` port **993** (SSL/TLS) or **143** (STARTTLS); SMTP the same host, port **587**, STARTTLS; username the full address; password the file's contents. `make vm-info` prints these settings, and `make show-credentials` prints each username with its password.

### Mailbox storage

| Variable | Default | Meaning |
|---|---|---|
| `postfix_imap_enabled` | `true` when `postfix_mailboxes` is non-empty | Installs `dovecot-imapd` + `dovecot-lmtpd`, opens IMAP, and points `virtual_transport` at Dovecot. With no mailboxes, Dovecot is still installed but serves only SASL for submission. |
| `postfix_mail_dir` | `/var/mail/vhosts` | Root of the Maildir tree: `<mail_dir>/<domain>/<local part>/Maildir`. |
| `postfix_vmail_user` / `_uid` / `_gid` | `vmail` / `5000` / `5000` | Unprivileged owner of all stored mail. |

Dovecot auto-creates and subscribes `Drafts`, `Sent`, `Junk`, and `Trash` alongside `INBOX`. There are no quotas: mail is limited only by the boot volume (50 GB by default). **The Maildirs are the only copy of your mail** and nothing here backs them up, so `make vm-destroy` destroys them; see the README's day-2 table for an `rsync` one-liner.

### Role defaults you might override (in `all.yml`)

| Variable | Default | Meaning |
|---|---|---|
| `postfix_message_size_limit` | `26214400` (25 MB) | Largest accepted message. |
| `postfix_rbls` | `[]` | DNS blocklists checked on port 25, e.g. `["zen.spamhaus.org"]`. Off by default: Spamhaus refuses queries that arrive through cloud providers' shared resolvers. It needs a private resolver or a registered Spamhaus DQS key. |
| `postfix_srs_domain` | first served domain | Domain used in SRS addresses. |

---

## TLS

The same certificate serves SMTP (25, 587) and IMAP (143, 993).

| Variable | Default | Meaning |
|---|---|---|
| `postfix_letsencrypt_enabled` | `false` | `false` uses Ubuntu's self-signed *snakeoil* certificate: encryption works, but mail clients warn about it. `true` makes certbot obtain a certificate for `dnssmtp_mail_hostname` over HTTP-01 on port 80 (certbot's own temporary listener) and renew it automatically. Enable it only **after** the host name resolves publicly (README Phase 2). |
| `postfix_letsencrypt_email` | `dnssmtp_admin_email` | Let's Encrypt account e-mail (expiry notices). |

A hook at `/etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh` reloads Postfix and Dovecot after every renewal. It is a directory hook rather than `--deploy-hook` so it also applies to certificates issued before this role ran.

TLS 1.2 is the floor everywhere. Port 587 requires TLS before AUTH, IMAP requires it before LOGIN, and port 25 offers TLS but cannot require it, as inbound MX servers must accept plain connections.

---

## Optional smarthost relay

Mail **from** the served domains can go through an authenticated relay instead of being delivered directly, for example [OCI Email Delivery](https://docs.oracle.com/en-us/iaas/Content/Email/home.htm), which gives 3,000 emails/month free. Forwarded (SRS) mail **always** goes direct, because a relay would reject its foreign `From:`.

| Variable | Default | Meaning |
|---|---|---|
| `postfix_relayhost` | `""` | `""` delivers directly. Otherwise `[host]:port`, e.g. `[smtp.email.us-ashburn-1.oci.oraclecloud.com]:587`. TLS is enforced toward it. |
| `postfix_relayhost_username` | `""` | From a file: `"{{ lookup('file', '/etc/dns-smtp-server/relay_username') \| trim }}"` |
| `postfix_relayhost_password` | `""` | From a file: `"{{ lookup('file', '/etc/dns-smtp-server/relay_password') \| trim }}"` |

For OCI Email Delivery:

- create SMTP credentials under *My profile -> SMTP credentials*;
- add every sending address as an **approved sender**;
- set up its DKIM for your domains or keep ours (both signatures are fine);
- add its SPF include to `dnssmtp_spf`.

---

## Role defaults

The playbooks set these from the `dnssmtp_*` settings above. They are listed so the roles can be reused or tested on their own.

### `os_hardening`

| Variable | Default | Meaning |
|---|---|---|
| `os_hardening_ops_user` | `ops` | Operator account: sudo without password, same SSH key as the cloud-init `ubuntu` user. |
| `os_hardening_public_ports` | 25/tcp, 53/tcp, 53/udp, 80/tcp, 143/tcp, 587/tcp, 993/tcp | Ports opened in the VM firewall. Each rule is inserted **before** the `REJECT` rule that OCI's Ubuntu images ship, live and in `/etc/iptables/rules.v4`. SSH is already allowed by the image. |
| `os_hardening_rules_v4_path` | `/etc/iptables/rules.v4` | Persisted ruleset loaded at boot. |
| `os_hardening_fail2ban_jails` | `sshd`, `postfix`, `postfix-sasl`, `dovecot` | fail2ban jails (systemd journal backend): `[{name, filter?}]`. A ban lasts 1 h after 5 failures in 10 min. The postfix jails override the filter's journal match to `postfix@-.service`, the unit Ubuntu runs Postfix under; `dovecot` covers failed IMAP and submission logins. |
| `os_hardening_swap_enabled` / `_size` / `_swapfile_path` | `true` / `2G` / `/swapfile` | Swap for the 1 GB micro VM. |

sshd always gets `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, and `PermitRootLogin no`. Unattended security upgrades are enabled.

### `bind9`

| Variable | Default | Meaning |
|---|---|---|
| `bind9_zones` | derived | `[{name, ttl, hostmaster, nameservers, records}]`. |
| `bind9_zone_dir` | `/etc/bind/zones` | Where zone files are written. |
| `bind9_default_ttl` | `3600` | TTL when a zone doesn't set one. |
| `bind9_soa_refresh` / `_retry` / `_expire` / `_negative_ttl` | `3600` / `900` / `1209600` / `300` | SOA timers. `_negative_ttl` sets how long resolvers cache "does not exist". |
| `bind9_secondaries` | `[]` | See [DNS](#host-names-and-extra-nameservers). |
| `bind9_rrl_responses_per_second` | `10` | Response rate limiting: stops the server being used for DNS amplification attacks. |

BIND runs **authoritative only**: recursion and cache queries are refused, the version is hidden, and IPv6 listening is off.

### `opendkim`

| Variable | Default | Meaning |
|---|---|---|
| `opendkim_keys` | derived | `[{domain, selector, private_key_src}]`. `private_key_src` is a path on the controller. |
| `opendkim_socket` | `inet:8891@127.0.0.1` | Milter socket Postfix connects to. |
| `opendkim_internal_hosts` | `127.0.0.1`, `::1`, `localhost` | Mail from these hosts is signed. Port-587 mail is signed through Postfix's `ORIGINATING` tag. |

Signing uses `relaxed/simple` canonicalization, rsa-sha256, and oversigns `From`. Addresses at subdomains, e.g. system mail from `mail.<domain>`, sign with the parent domain's key.

### `alpine`

Installs the Alpine text-mode client on the VM so mail can be read over SSH, with no extra port exposed and no password stored on the server (it prompts).

| Variable | Default | Meaning |
|---|---|---|
| `alpine_accounts` | derived from `postfix_mailboxes` | Mail addresses; the **first** is the INBOX, the rest appear as folder collections. |
| `alpine_personal_name` | `""` | Display name in the `From:` header. |
| `alpine_user_domain` | domain of the first account | Domain for unqualified addresses. |
| `alpine_imap_host` / `_imap_port` / `_smtp_port` | `127.0.0.1` / `993` / `587` | Loopback only. |
| `alpine_validate_cert` | `false` | The certificate is issued for the mail host name, not for `127.0.0.1`, so validation is off for these loopback connections. |
| `alpine_users` | `[ops]` | Users whose `~/.pinerc` gets the managed keys. |
| `dnssmtp_install_alpine` | `true` | Set to `false` in `all.yml` to skip the role. |

Alpine writes its own `~/.pinerc`, and a value there (even an empty one) shadows `/etc/pine.conf`. The role therefore writes the global file **and** sets the same keys per user, leaving every other setting the user changed in the client untouched.

### `postfix`

| Variable | Default | Meaning |
|---|---|---|
| `postfix_myhostname` | derived (`dnssmtp_mail_hostname`) | Postfix identity, HELO name, and TLS certificate name. |
| `postfix_domains` | derived | Domains accepted inbound (virtual mailbox domains). |
| `postfix_proxy_interfaces` | derived (reserved public IP) | OCI maps the public IP 1:1 onto the private IP. Postfix must know it to recognize itself as the final MX. |
| `postfix_root_alias` | derived (`dnssmtp_admin_email`) | Destination for root's local mail. |
| `postfix_milters` | `["inet:127.0.0.1:8891"]` | Milters (OpenDKIM). |

---

## Controller container settings

Set in [`ansible/docker-compose.yml`](../ansible/docker-compose.yml). Normally you don't touch them.

| Setting | Meaning |
|---|---|
| Mount `~/.ssh -> /mnt/ssh:ro` | Copied to `/root/.ssh` with 0600 permissions by the entrypoint. OpenSSH rejects keys with Windows-style permissions. |
| Mount `~/.oci -> /mnt/oci:ro` | Same treatment for the OCI API key. |
| Mount `~/.dns-smtp-server -> /etc/dns-smtp-server:ro` | Inventory, `group_vars`, secrets. Read-only on purpose. |
| Mount `/var/run/docker.sock` | Lets molecule start test containers on the host's Docker. |
| `UV_BASE_IMAGE` (env) | Base image, default `ghcr.io/astral-sh/uv:python3.14-bookworm-slim`. Override to use a registry mirror. |
| `ANSIBLE_IMAGE_TAG` (env) | Image name. The default uses the reserved `.invalid` domain, so an accidental push can never reach a public registry. |
| `ANSIBLE_ROLES_PATH`, `ANSIBLE_PIPELINING`, `ANSIBLE_DEPRECATION_WARNINGS` | Set as environment variables because Ansible ignores an `ansible.cfg` inside a world-writable (Windows-mounted) directory. |

The Python tooling is pinned in [`pyproject.toml`](../pyproject.toml) and `uv.lock` (Python 3.14, `deploy` dependency group). `oci-cli` is installed as a separate `uv tool`, so its version pins can't conflict with Ansible. After changing dependencies, run `uv lock` and `make ansible-build`.

---

## What gets generated on the VM

For orientation when you SSH in (`ssh ops@<reserved-ip>`):

| Path | Content |
|---|---|
| `/etc/bind/named.conf.options`, `named.conf.local`, `zones/db.*` | BIND configuration and zones |
| `/etc/postfix/main.cf`, `master.cf` (submission block) | Postfix configuration |
| `/etc/postfix/virtual`, `vmailbox`, `sender_login`, `tls_policy`, `sasl_passwd` (0600), `sender_relay.pcre` | Postfix lookup tables |
| `/etc/dovecot/dovecot.conf`, `/etc/dovecot/passwd` (0640, hashes only), `/etc/dovecot/users` | SASL + IMAP backend |
| `/var/mail/vhosts/<domain>/<user>/Maildir` | Stored mail, owned by `vmail` |
| `/etc/opendkim.conf`, `/etc/opendkim/{KeyTable,SigningTable,TrustedHosts}`, `/etc/opendkim/keys/*.private` (0600) | DKIM signing |
| `/etc/default/postsrsd` (`SRS_DOMAIN`, `SRS_EXCLUDE_DOMAINS`) | SRS |
| `/etc/letsencrypt/live/<mail host>/` | TLS certificate, when enabled |
| `/etc/iptables/rules.v4`, `/etc/fail2ban/jail.local`, `/etc/ssh/sshd_config.d/10-hardening.conf` | Hardening |

Useful commands on the VM:

- `sudo named-checkconf -z`
- `dig @127.0.0.1 <zone> SOA`
- `sudo postfix check`
- `mailq`
- `sudo doveadm user <address>` -- resolve a mailbox
- `sudo doveadm mailbox status -u <address> messages INBOX` -- count stored messages
- `sudo doveconf -n` -- the effective Dovecot configuration
- `sudo journalctl -u postfix@- -f`
- `sudo fail2ban-client status`

---

## Commands

`make help` lists them all; these are the ones that read or change the
configuration described above.

| Command | What it does |
|---|---|
| `make vm-create` | Network, VM and reserved public IP. Re-run after changing `dnssmtp_allow_ping` or anything else in the security list. |
| `make vm-prep` | Applies every role. Re-run after **any** edit to `all.yml`: records, mailboxes, aliases, submission users, secondaries, TLS. |
| `make vm-verify` | goss on the VM plus checks from the controller: zones, MX, DKIM, no open resolver, STARTTLS, IMAPS, and a cleartext IMAP login that must be refused. |
| `make dns-check` | Every configured record, queried on the VM and through a public resolver, with the answer shown. Separates "BIND is not serving it" from "not delegated yet". |
| `make vm-info` | The VM's address, SSH command and the IMAP/SMTP settings for a mail client. |
| `make show-credentials` | Each mail login with its password, read from the local files. |
| `make dkim-keygen DOMAIN=... [SELECTOR=s1]` | New DKIM key. Refuses to overwrite; use a new selector to rotate. |
| `make smtp-password LOGIN=...` | New account password. Refuses to overwrite. |
| `make lint` | ASCII check, yamllint and ansible-lint at the production profile. |
| `make test-roles` / `make test-role ROLE=postfix` | molecule: converge, idempotence and goss, per role. |

Both diagnostics (`vm-info`, `dns-check`) are read-only and skip the wait for
SSH, so they work when the host is not answering.
