# FitApp DevSecOps platform — explained from zero

> Goal of this document: be able to explain to anyone (a professor, a teammate, a jury)
> **what** each piece of the platform is, **how** we built it, and **why** we made each choice.
> No prior knowledge assumed.

---

## Table of contents

1. [The big picture in one page](#1-the-big-picture-in-one-page)
2. [The 3 git repositories](#2-the-3-git-repositories)
3. [Azure: the account, its limits and our choices](#3-azure-the-account-its-limits-and-our-choices)
4. [Terraform: creating the machines and the network](#4-terraform-creating-the-machines-and-the-network)
5. [Ansible: configuring the machines](#5-ansible-configuring-the-machines)
6. [k3s: the Kubernetes cluster](#6-k3s-the-kubernetes-cluster)
7. [Argo CD and GitOps](#7-argo-cd-and-gitops)
8. [The gitops repo in detail: environments, security, the generic chart](#8-the-gitops-repo-in-detail)
9. [The life of a request: from the browser to a pod](#9-the-life-of-a-request-from-the-browser-to-a-pod)
10. [The 4 commands: up, stop, destroy, status](#10-the-4-commands-up-stop-destroy-status)
11. [Problems we hit and how we solved them](#11-problems-we-hit-and-how-we-solved-them)
12. [Security summary (the "Sec" in DevSecOps)](#12-security-summary)
13. [Costs](#13-costs)
14. [What comes next](#14-what-comes-next)
15. [Questions the professor may ask (with answers)](#15-questions-the-professor-may-ask)
16. [Glossary](#16-glossary)

---

## 1. The big picture in one page

We built a **platform**: the place where the FitApp microservices will run, plus the automation that
creates it, configures it and deploys to it. Everything is **code stored in git**. Nothing was clicked by hand
in the Azure portal, and nobody logs into a server to install things manually.

There are **4 layers**. Each layer is built by the previous one:

```
 LAYER 0  bootstrap/  (Terraform, run once)        → permanent storage for Terraform's memory + budget alert
     │
 LAYER 1  terraform/  (Terraform)                  → network, firewall rules, public IPs, 2 Linux VMs, Key Vault
     │
 LAYER 2  ansible/    (Ansible)                    → inside the VMs: security hardening, Kubernetes (k3s), Argo CD
     │
 LAYER 3  fitapp-gitops repo  (Argo CD)            → inside Kubernetes: environments dev/test/prod, apps, security rules
```

What runs today:

```
                                   Internet
                                       │
          ┌────────────────────────────┼─────────────────────────────────────────┐
          │ Azure · Sweden Central     │                                         │
          │                            ▼ public IP 20.240.199.229                │
          │   ┌──────────────── k3s-master (10.0.1.10) ───────────────┐          │
          │   │ Kubernetes control plane · Argo CD · Traefik (ingress) │          │
          │   │ prod pod #1                                            │          │
          │   └────────────────────────────┬───────────────────────────┘          │
          │              private network 10.0.1.0/24                              │
          │   ┌──────────────── k3s-worker-1 (10.0.1.11) ─────────────┐          │
          │   │ dev pod · test pod · prod pod #2                       │          │
          │   └───────────────────────────────────────────────────────┘          │
          └──────────────────────────────────────────────────────────────────────┘
                 ▲ Argo CD pulls the desired state from GitHub (fitapp-gitops)
```

Three URLs answer from the internet, one per environment:

| Environment | URL |
|---|---|
| dev | http://demo-service-dev.20.240.199.229.nip.io |
| test | http://demo-service-test.20.240.199.229.nip.io |
| prod | http://demo-service.20.240.199.229.nip.io |

*(The IP changes if the platform is destroyed and rebuilt.)*

The app currently deployed, `demo-service`, is **podinfo**, a small public demo web app. It is a stand-in:
when the team's real `auth-service` image exists, it replaces podinfo by changing one line.

---

## 2. The 3 git repositories

| Repo | Contains | Who reads it | Analogy |
|---|---|---|---|
| `fitapp-infra` | Terraform + Ansible + scripts | Us (and later an infra pipeline) | The **building plans** |
| `fitapp-gitops` | Kubernetes YAML: environments, apps, security rules | **Argo CD**, automatically | The **order sheet** of the kitchen |
| `fitapp-app` (the developers') | Java microservices code | The CI pipeline (next step) | The **recipes** |

**Why separate repos?**
- Different people, different rhythms: developers push code many times a day; the infrastructure changes rarely.
- Different permissions: the CI pipeline only needs to write *one line* (an image tag) in the gitops repo; it never needs access to the infrastructure or the cluster.
- Clean history: `git log` of the gitops repo is literally the **deployment history** of the platform.

---

## 3. Azure: the account, its limits and our choices

### 3.1 The constraints of "Azure for Students"

We checked the account with the Azure CLI before writing any code (that's how we chose everything below):

| Constraint found | Value | Consequence |
|---|---|---|
| Credit | ~$84 left | Infrastructure must be **ephemeral**: created for demos, destroyed after |
| Allowed regions (policy) | swedencentral, francecentral, germanywestcentral, polandcentral, norwayeast | We could not use any other region |
| Total vCPU per region | **6** | At most 3 VMs of 2 vCPU |
| Classic B-series quota (B2s, B2ms) | 4 vCPU, and **not even offered** in Sweden Central for our subscription | That is why the portal showed "no machine available" |
| New B-series v2 quota (Basv2) | **10** vCPU | ✅ We use this family |

We also found where previous credit had gone: an old **public IP address** kept for months after its VM
was gone (~$15). Lesson applied: Azure bills a Standard public IP even when nothing uses it, so our
`destroy` deletes everything, and a budget alert watches spending.

### 3.2 Region: Sweden Central
- Allowed by the student policy.
- The B-series v2 sizes are available there for our subscription.
- Latency from Morocco (~50–60 ms) is fine for a project.

### 3.3 Machine sizes

| VM | Size | vCPU / RAM | Price | Why this one |
|---|---|---|---|---|
| `k3s-master` | Standard_B2als_v2 | 2 / 4 GB | ~$0.039/h | The control plane + Argo CD fit in 4 GB; cheapest 2-vCPU size |
| `k3s-worker-1` | Standard_B2as_v2 | 2 / 8 GB | ~$0.078/h | Java microservices need RAM; 8 GB for the apps |
| `k3s-worker-2` *(optional)* | Standard_B2as_v2 | 2 / 8 GB | ~$0.078/h | Added only for the final demo: `worker_count = 2` |

**"B" = burstable**: cheap VMs that accumulate CPU credits when idle and spend them under load. Perfect for a
platform that is idle most of the time.

**Why not 3 VMs all the time?** 6 vCPU is the regional maximum, and the credit is limited. Two nodes are
enough to show a real multi-node cluster (pods spread across machines). The third is one variable away.

### 3.4 Why Ubuntu Server 24.04 LTS
LTS = Long Term Support (security updates until 2029+). It is the most documented OS for Kubernetes and Ansible.

---

## 4. Terraform: creating the machines and the network

### 4.1 What is Terraform?
Terraform is an **Infrastructure as Code (IaC)** tool. Instead of clicking in the Azure portal, we **describe**
what we want in `.tf` files ("I want a network, two VMs of this size, these firewall rules"), and Terraform
calls the Azure API to make reality match the description.

The 4 commands to know:

| Command | What it does | Changes Azure? |
|---|---|---|
| `terraform init` | Downloads the Azure plugin ("provider"), connects to the state storage | No |
| `terraform plan` | **Preview**: compares the code with reality and lists what *would* change | No |
| `terraform apply` | Executes the plan | **Yes** |
| `terraform destroy` | Deletes everything this code created | **Yes** |

### 4.2 The "state": Terraform's memory
Terraform keeps a file called the **state** that records "resource X in my code = this real object in Azure
with this ID". Without it, Terraform would not know what it already created.

**Where we store it, and why it matters:**
- Not on a laptop (lost laptop = Terraform forgets everything; teammates can't work).
- Not in git (it can contain sensitive values).
- → In an **Azure Storage Account**, in a private container called `tfstate`.
  - **Locking**: while one person runs `apply`, nobody else can (prevents two people breaking each other's changes).
  - **Versioning**: every change of the state is kept; we can go back to an older version.
  - **No access keys**: the storage account refuses passwords/keys; only our Azure identity (Entra ID) with the role *Storage Blob Data Contributor* can read/write.

### 4.3 Layer 0 — `bootstrap/` (run once, permanent)
Chicken-and-egg problem: Terraform's state needs a storage account, but the storage account must be
created by someone. So `bootstrap/` is a tiny separate Terraform project, with its state kept locally, that creates:

| Resource | Purpose |
|---|---|
| Resource group `fitapp-tfstate-rg` | A "folder" in Azure for permanent things |
| Storage account `fitapptfstate30de7605` | Holds the state (container `tfstate`) and later database backups (container `backups`). Its name is derived from the subscription ID so it's unique worldwide and always the same |
| Role assignment | Gives *us* permission to read/write blobs in it |
| Budget `budget-fitapp-monthly` ($30) | E-mails when spending passes 50% and 90%, or is forecast to pass 100% |
| `terraform/backend.hcl` (local file) | Tells the main Terraform project where its state lives |

The storage account has `prevent_destroy = true`: Terraform refuses to delete it by accident.

### 4.4 Layer 1 — `terraform/` (ephemeral: created and destroyed for demos)

File by file:

#### `versions.tf` — tools and plugins
- Pins the provider versions (`azurerm ~> 4.81`, …) so every teammate gets the same behavior. The exact versions are locked in `.terraform.lock.hcl`, which is committed to git.
- `backend "azurerm" {}`: the state is remote (values in `backend.hcl`).
- `resource_provider_registrations = "none"`: explained in [§11](#11-problems-we-hit-and-how-we-solved-them).
- `purge_soft_delete_on_destroy = true`: when we destroy the Key Vault it is really deleted (not kept in a "recycle bin"), so the next `apply` can create a new one.
- `delete_os_disk_on_deletion = true`: deleting a VM deletes its disk, so no forgotten disks keep billing.

#### `variables.tf` — the knobs
Everything that may change is a variable with a default: region, VM sizes, `worker_count` (0–2, with a
validation rule that refuses more than the quota allows), disk size, IP ranges, auto-shutdown time…
We change behavior in `terraform.tfvars` without touching the code.

#### `main.tf` — resource group, naming, node list
- **Resource group `fitapp-rg`**: one "folder" containing *all* ephemeral resources. Deleting it = deleting everything.
- **Tags** on every resource (`project=fitapp`, `managed_by=terraform`, `lifecycle=ephemeral`): in the portal and on the bill you can see what belongs to the project and that it is managed by code.
- **`locals.nodes`**: one map that describes every machine (name, role, size, private IP). All the other resources (IPs, network cards, VMs) are created **from this map** with `for_each`. Adding a worker = one more entry, generated automatically from `worker_count`.
- **Admin IP detection**: our laptop's public IP is detected and becomes the only address allowed to SSH and to talk to Kubernetes.

#### `network.tf` — the network and the firewalls

**Virtual network (VNet) `10.0.0.0/16`**
A private network in Azure, like the LAN of a house. `10.0.0.0/16` means "every address from 10.0.0.0 to 10.0.255.255" (65,536 addresses). These are private addresses, not reachable from the internet.

**Subnet `snet-nodes` `10.0.1.0/24`**
A slice of the VNet (10.0.1.0 → 10.0.1.255) where the VMs live. We give fixed addresses:

| Machine | Private IP |
|---|---|
| k3s-master | 10.0.1.10 |
| k3s-worker-1 | 10.0.1.11 |
| k3s-worker-2 | 10.0.1.12 |

Fixed addresses make the configuration simple: the workers always know the master is at 10.0.1.10.

`default_outbound_access_enabled = false`: Azure used to give VMs "invisible" internet access by default; Microsoft is retiring that.
We disable it and give internet access **explicitly** (through public IPs). That's more predictable and more secure.

**NSG = Network Security Group = a firewall** attached to each machine's network card.
Rules are checked by priority (lowest number first); the first match wins.

*NSG of the master:*

| Priority | Rule | From | Port | Why |
|---|---|---|---|---|
| 100 | Allow SSH | **our IP only** | 22 | So Ansible / we can administer the machine |
| 110 | Allow Kubernetes API | **our IP only** | 6443 | So `kubectl` on our laptop can talk to the cluster |
| 120 | Allow web | Internet (everyone) | 80, 443 | The application must be reachable by users |
| 4000 | **Deny everything else** from the internet | Internet | all | Explicit "closed by default" |

*NSG of the workers:*

| Priority | Rule | Why |
|---|---|---|
| 4000 | **Deny everything** from the internet | Workers are never reachable from outside |

Traffic **between** the VMs (inside 10.0.0.0/16) is allowed by Azure's built-in rule *AllowVnetInBound*.
Kubernetes needs it: workers talk to the master on 6443, and pods talk to each other across machines (Flannel, UDP 8472).

> Why is the Kubernetes API (6443) not open to everyone? Because whoever can talk to it with valid credentials
> controls the whole cluster. Restricting it to our IP adds a network barrier on top of the certificate.

#### `vms.tf` — public IPs, network cards, VMs, auto-shutdown

**Public IPs — one per machine. Why also on the workers?**
Every machine needs **outbound** internet: install updates (`apt`), download k3s, download container images.
Without a public IP (and without the old implicit access), a worker can't reach the internet. The alternatives:

| Option | Cost | Verdict |
|---|---|---|
| NAT Gateway | ~$32/month | Too expensive for our credit |
| Use the master as a router for the workers | free | Complex to configure and debug |
| **A public IP on each worker, with the NSG refusing all inbound traffic** | ~$0.005/h each | ✅ Simple, cheap, and still closed from the outside |

So the worker IPs are **outbound only**: the worker can go out, nobody can come in.

Static Standard SKU IPs: the address doesn't change when the VM restarts (Basic SKU IPs were retired by Azure).

**Network interface (NIC)**: the virtual network card of each VM. It connects the VM to the subnet with its fixed
private IP, attaches its public IP, and gets the NSG (master NSG or workers NSG depending on the role).

**The VMs (`azurerm_linux_virtual_machine`)** — each important line:

| Setting | Value | Why |
|---|---|---|
| `computer_name` | k3s-master, k3s-worker-1 | It becomes the Linux hostname and the Kubernetes node name |
| `disable_password_authentication` | true | **Only SSH keys**, no password to guess or brute-force |
| `admin_ssh_key` | `~/.ssh/fitapp_azure.pub` | Our public key is put on the VM; the private key never leaves the laptop |
| `os_disk` | 64 GB Standard SSD | Room for container images and logs; SSD for speed; "Standard" for price |
| `source_image_reference` | Canonical / ubuntu-24_04-lts / server / latest | Official Ubuntu image, always the latest patch |
| `secure_boot_enabled` + `vtpm_enabled` | true | **Trusted Launch**: the VM only boots signed bootloaders/kernels (protects against rootkits/bootkits) |
| `identity { SystemAssigned }` | — | A **managed identity**: the VM gets its own Azure identity, usable later to read Key Vault secrets **without any password** |
| `boot_diagnostics {}` | — | Lets us see the VM's console in the portal if it ever fails to boot |

**Auto-shutdown** (`azurerm_dev_test_global_vm_shutdown_schedule`)
Every VM is deallocated automatically at 23:00 (Morocco time). It's a **safety net** if someone forgets to stop
or destroy the platform, so a forgotten cluster can't eat the credit overnight.

#### `keyvault.tf` — the safe for secrets
Azure Key Vault stores secrets (database passwords, Firebase service account, …). Later, an operator in
Kubernetes (External Secrets) will read them and create Kubernetes secrets, so **no secret ever goes into git**.

| Setting | Why |
|---|---|
| Name `kv-fitapp-<random 6 chars>` | A deleted vault name stays reserved for days; a random suffix avoids clashes between rebuilds |
| `rbac_authorization_enabled = true` | Access controlled by Azure roles (modern), not legacy access policies |
| Role *Key Vault Administrator* for us | We can create/edit secrets |
| Role *Key Vault Secrets User* for each VM identity | The nodes can **only read** secrets: least privilege |
| `purge_protection_enabled = false` | Must be false so `destroy` can really delete it (fine for an ephemeral student platform) |

#### `inventory.tf` + `templates/inventory.tftpl` — the bridge to Ansible
After creating the VMs, Terraform **writes the Ansible inventory file** (the list of machines and how to reach
them) from the real IPs. Nobody copies IP addresses by hand, so there are no typos and it's always up to date.

#### `outputs.tf`
Prints useful information after `apply`: master public IP, each node's IPs, the SSH command, the Key Vault name.

---

## 5. Ansible: configuring the machines

### 5.1 What is Ansible and why not do it with Terraform?
Terraform **creates** things (it's good at "this VM must exist"). Ansible **configures** things inside a machine
("this package must be installed, this file must contain this, this service must run").

| | Terraform | Ansible |
|---|---|---|
| Job | Create cloud resources | Configure the inside of servers |
| Talks to | The Azure API | The VMs, over SSH |
| Re-run safely to fix drift? | Yes, for cloud resources | Yes, for OS configuration |

Using each tool for what it's good at is the industry-standard split.

**Agentless**: Ansible installs nothing on the VMs. It connects over SSH, runs small Python programs and
disconnects.

**Idempotent**: running the playbook 1 time or 10 times gives the same result. If something is already
correct, Ansible changes nothing (it reports `ok` instead of `changed`). So re-running it is always safe, and it
repairs anything someone changed by hand.

### 5.2 How Ansible reaches the machines: the bastion pattern
- The master has SSH open **for our IP only**.
- The workers have **no** SSH open to the internet at all.
- So Ansible connects to the master, and **jumps** from the master to the workers over the private network
  (`ProxyCommand` in the generated inventory). The master acts as a **bastion** (jump host).

```
laptop ──SSH──► k3s-master (public IP) ──SSH over 10.0.1.0/24──► k3s-worker-1 (10.0.1.11)
```

Host keys: each rebuilt VM has new SSH host keys. We keep them in a separate file (`ansible/.known_hosts`) that the
scripts reset on rebuild, so we keep host-key checking on for new machines without false alarms after a rebuild.

### 5.3 The playbook `site.yml`: 5 steps, in order

| Step | Runs on | What |
|---|---|---|
| 0 | all | Wait until SSH answers and **cloud-init** (Azure's first-boot setup) has finished, otherwise `apt` would be locked |
| 1 — role `common` | all | OS hardening |
| 2 — role `k3s_server` | master | Install Kubernetes control plane |
| 3 — role `k3s_agent` | workers | Install Kubernetes agent and **join** the master |
| 4 — roles `kubeconfig` + `argocd` | master | Give our laptop access to the cluster; install Argo CD and connect it to the gitops repo |

### 5.4 Role `common` — hardening every machine

| Task | Why |
|---|---|
| Timezone Africa/Casablanca | Logs show our local time |
| `apt dist-upgrade` | Install all security patches before anything else |
| Install `fail2ban` | Automatically bans IPs that fail SSH logins repeatedly |
| Enable unattended-upgrades | Security updates are installed automatically every day |
| SSH hardening file | `PermitRootLogin no` (nobody logs in as root), `PasswordAuthentication no` (keys only), `MaxAuthTries 3`, `X11Forwarding no`, idle sessions disconnected. The file is **validated with `sshd -t`** before being applied, so a typo can never lock us out |
| Kernel settings (sysctl) | More `inotify` watchers (Kubernetes and log collectors need many); `kptr_restrict` and `dmesg_restrict` hide kernel memory addresses/logs from non-root users |
| Reboot if needed | If the upgrade installed a new kernel, reboot so it is actually used |

### 5.5 Role `k3s_server` — the control plane
1. Writes `/etc/rancher/k3s/config.yaml` (explained in [§6.3](#63-our-k3s-configuration-explained)).
2. Installs k3s **at a pinned version** (`v1.37.2+k3s1`): every rebuild gets exactly the same Kubernetes.
3. Waits until the master node is `Ready`.
4. Reads the **join token** (the secret that lets a machine join this cluster) and keeps it **in memory only**,
   with `no_log: true`, so it never appears in the logs and is never written into the repo.

### 5.6 Role `k3s_agent` — the workers join
1. Writes the agent config (its private IP, the network interface).
2. Installs k3s in **agent** mode with `K3S_URL=https://10.0.1.10:6443` and the token from the master.
   The agent contacts the master, proves it knows the token, and becomes a node of the cluster.
3. Waits until the node is `Ready` (checked from the master).
4. Labels it `node-role.kubernetes.io/worker` so `kubectl get nodes` shows its role.

### 5.7 Role `kubeconfig` — access from the laptop
Copies the cluster's admin credentials (`/etc/rancher/k3s/k3s.yaml`) to `~/.kube/fitapp-azure.yaml` on our laptop,
replacing `127.0.0.1` by the master's public IP. File mode `0600` (only us can read it); never committed to git.

### 5.8 Role `argocd` — the one thing Ansible installs inside Kubernetes
1. Creates namespace `argocd`, applies the **official Argo CD manifest at a pinned version** (v3.6.1).
2. Waits until its components are running.
3. Creates **one** Argo CD Application, called `root`, pointing at `bootstrap/` in the gitops repo.

From this moment, **Argo CD installs everything else** inside the cluster from git ([§7](#7-argo-cd-and-gitops)).

---

## 6. k3s: the Kubernetes cluster

### 6.1 Kubernetes in 6 sentences
- We give Kubernetes a **description** of what should run ("3 copies of this container image, reachable on this URL").
- Kubernetes **places** the containers (pods) on the machines (nodes) that have free resources.
- It **restarts** a container that crashes and **moves** pods away from a machine that dies.
- It **load-balances** traffic between the copies of an app (a *Service*).
- It **only sends traffic to pods that are ready** (*readiness probe*).
- It **updates** an app without downtime by replacing pods one at a time (*rolling update*).

The 2 (or 3) VMs behave like **one big computer** for us: we never choose "this pod on that machine" by hand.

### 6.2 k3s vs "k8s"
"k8s" is just short for Kubernetes. **k3s** is a **CNCF-certified Kubernetes distribution** by Rancher/SUSE:
the same API, same `kubectl`, same YAML, same Helm charts, but packaged as a single small binary. Batteries included:

| Built into k3s | What it does |
|---|---|
| containerd | Runs the containers |
| Flannel | The pod network across machines (each pod gets an IP; pods on different nodes talk through a VXLAN tunnel) |
| CoreDNS | Internal DNS: `demo-service.prod` resolves to the prod Service |
| Traefik | The **ingress controller**: the web entry point that routes `http://<name>.<domain>` to the right app |
| ServiceLB | Exposes Traefik on ports 80/443 of the nodes |
| kube-router network policy controller | **Enforces NetworkPolicies** (our isolation rules between environments) |
| local-path provisioner | Disk volumes on the node's disk (for databases later) |
| metrics-server | CPU/RAM usage of pods (`kubectl top`, autoscaling) |

Why k3s instead of a managed AKS cluster or vanilla kubeadm:
- **Cheaper**: AKS would add a load balancer + public IP (~$20/month), about 20% of our credit.
- **Lighter**: the control plane needs ~0.5 GB RAM instead of ~2 GB, which matters on 4 GB / 8 GB VMs.
- **Educational**: we build the cluster ourselves (control plane + node join), which shows real infrastructure work.

### 6.3 Our k3s configuration explained
`/etc/rancher/k3s/config.yaml` on the master:

| Setting | Why |
|---|---|
| `node-ip: 10.0.1.10` / `advertise-address` | The cluster talks over the **private** network, never over the internet |
| `flannel-iface: eth0` | Pod-to-pod tunnel uses the private network card |
| `tls-san: [public IP, private IP]` | The API server's certificate is valid for the public IP too, so `kubectl` from our laptop trusts it |
| `write-kubeconfig-mode: 0600` | The admin credential file on the master is readable by root only |
| `secrets-encryption: true` | Kubernetes Secrets are **encrypted at rest** in the cluster database |
| master schedulable | With only 1–2 workers, we let apps run on the master too (that's why one prod pod runs there) |

### 6.4 What we verified
```
$ kubectl get nodes -o wide
k3s-master     Ready   control-plane   v1.37.2+k3s1   10.0.1.10   Ubuntu 24.04.5 LTS
k3s-worker-1   Ready   worker          v1.37.2+k3s1   10.0.1.11   Ubuntu 24.04.5 LTS
```

---

## 7. Argo CD and GitOps

### 7.1 GitOps in one sentence
**A git repository describes what must run in the cluster, and a robot inside the cluster keeps the cluster
equal to the repository.**

| Without GitOps | With GitOps |
|---|---|
| Someone runs `kubectl apply` or a pipeline SSHes into servers | Nobody touches the cluster; we change files in git |
| "Who changed this? What's running?" — nobody knows | `git log` = complete history of every change |
| Rollback = panic | Rollback = `git revert` |
| The CI pipeline needs cluster admin credentials | The CI pipeline only needs to commit to a git repo |
| Manual changes stay forever (drift) | Manual changes are **automatically undone** |

### 7.2 Argo CD: the robot
Argo CD runs **inside** the cluster (namespace `argocd`). Every ~3 minutes (or immediately when we click
Refresh) it:
1. reads the gitops repo from GitHub (**pull**: the cluster reaches out to GitHub; nothing reaches into the cluster),
2. renders the YAML (plain files or Helm charts),
3. compares it with what is really running,
4. applies the differences.

Its main components (the 7 pods we saw):

| Pod | Role |
|---|---|
| `argocd-server` | Web UI + API |
| `argocd-repo-server` | Clones git, renders Helm/YAML |
| `argocd-application-controller` | Compares git vs cluster and syncs |
| `argocd-applicationset-controller` | Generates Applications automatically (our ApplicationSet) |
| `argocd-redis` | Cache |
| `argocd-dex-server` | Single sign-on (unused for now) |
| `argocd-notifications-controller` | Notifications (Slack/Teams/mail, later) |

**Sync policy** of all our apps: `automated` + `prune` + `selfHeal`:
- **automated**: a new commit is applied without anyone clicking,
- **prune**: something deleted from git is deleted from the cluster,
- **selfHeal**: something changed by hand in the cluster is put back as git says.

### 7.3 The chain of applications ("app of apps")

```
root  (created once by Ansible → reads bootstrap/)
 ├── platform        (Application → reads platform/: namespaces, quotas, network policies)   sync-wave -1 = first
 └── microservices   (ApplicationSet → one Application per folder envs/<env>/<service>/)
       ├── demo-service-dev    → namespace dev
       ├── demo-service-test   → namespace test
       └── demo-service-prod   → namespace prod
```

- **Why "root"?** Ansible creates only this one object. Everything else is declared in git, so even Argo CD's own
  configuration of what to deploy is versioned.
- **Sync wave -1 on `platform`**: namespaces and security rules are created *before* the apps that live in them.
- **ApplicationSet with a git "files" generator**: Argo CD scans the repo for `envs/*/*/values.yaml`. Each match
  becomes an Application named `<service>-<env>`, deploying the generic chart into namespace `<env>`.
  → **Adding a microservice or an environment = adding a folder.** No Argo CD configuration to edit.

What we verified:
```
$ kubectl -n argocd get applications
demo-service-dev    Synced   Healthy
demo-service-prod   Synced   Healthy
demo-service-test   Synced   Healthy
platform            Synced   Healthy
root                Synced   Healthy
```

---

## 8. The gitops repo in detail

```
fitapp-gitops/
├── bootstrap/            what "root" reads: platform.yaml, microservices.yaml
├── platform/             namespaces.yaml, quotas.yaml, networkpolicies.yaml
├── charts/microservice/  ONE generic Helm chart used by every microservice
└── envs/
    ├── cluster.yaml      domain: 20.240.199.229.nip.io
    ├── dev/demo-service/values.yaml
    ├── test/demo-service/values.yaml
    └── prod/demo-service/values.yaml
```

### 8.1 Environments = namespaces
A **namespace** is a logical partition of the cluster. dev, test and prod are 3 namespaces on the **same**
cluster. A separate cluster per environment would be the norm in a company; with our budget, namespaces
with strong isolation are the realistic solution. Isolation comes from 3 mechanisms:

**1. Pod Security Standard "restricted"** (label on each namespace)
Kubernetes **refuses** to start any pod in dev/test/prod that:
- runs as root,
- can escalate privileges,
- keeps Linux capabilities,
- has no seccomp profile.

**2. ResourceQuota + LimitRange** (`quotas.yaml`)

| | dev | test | prod |
|---|---|---|---|
| CPU requests max | 1 | 1 | 2 |
| Memory requests max | 2 Gi | 2 Gi | 4 Gi |
| Memory limits max | 3 Gi | 3 Gi | 6 Gi |
| Pods max | 20 | 20 | 40 |

A bug in dev (e.g. a memory leak, or 100 pods by mistake) **cannot starve prod**. The LimitRange gives
default limits to any container that forgets to declare them.

**3. NetworkPolicies** (`networkpolicies.yaml`) — zero trust between environments
- `default-deny-ingress`: by default, **nothing** can reach a pod.
- `allow-same-env-and-ingress`: allow traffic from pods of the **same** namespace, and from the ingress
  controller (Traefik, in `kube-system`) so users can still reach the apps.

Verified with test pods:
```
dev  -> dev  : ALLOWED      test -> test : ALLOWED
dev  -> test : BLOCKED      test -> dev  : BLOCKED
dev  -> prod : BLOCKED      test -> prod : BLOCKED
```

### 8.2 The generic Helm chart `charts/microservice`
**Helm** = a templating tool for Kubernetes YAML. A **chart** is a set of YAML templates with variables (values).
We write the Kubernetes YAML **once**, and every microservice in every environment only provides a short
`values.yaml`. With N microservices × 3 environments, that's a huge saving and guarantees every service follows
the same security rules.

How the values are combined (the last one wins):
```
charts/microservice/values.yaml     defaults (image, resources, probes…)
  + envs/cluster.yaml               cluster-wide (domain)
  + envs/<env>/<service>/values.yaml  this service in this environment (replicas, image tag, env vars)
```

**`deployment.yaml`** — how the app runs, line by line:

| Setting | Why |
|---|---|
| `replicas` | dev/test: 1, prod: 2 (high availability) |
| `strategy: RollingUpdate, maxUnavailable: 0, maxSurge: 1` | During an update a new pod starts **before** an old one stops: **zero downtime** |
| `revisionHistoryLimit: 3` | Keep the last 3 versions for quick rollback |
| `runAsNonRoot`, `runAsUser: 10001` | The process never runs as root |
| `seccompProfile: RuntimeDefault` | Blocks dangerous Linux system calls |
| `allowPrivilegeEscalation: false` | The process can't gain more rights than it started with |
| `readOnlyRootFilesystem: true` | An attacker can't modify the container's files; only `/tmp` and `/data` are writable (in-memory `emptyDir`) |
| `capabilities: drop ALL` | Removes every special Linux privilege |
| `automountServiceAccountToken: false` | The app gets no Kubernetes API credential it doesn't need |
| `livenessProbe` `/healthz` | If it fails, Kubernetes **restarts** the container |
| `readinessProbe` `/readyz` | Until it succeeds, the pod receives **no traffic** |
| `resources.requests / limits` | Requests = what the scheduler reserves; limits = maximum memory before the container is killed |
| `topologySpreadConstraints` on hostname | The 2 prod replicas go to **different machines** (verified: one on master, one on worker), so losing one VM doesn't take prod down |

**`service.yaml`**: a stable internal address (`demo-service.prod`, port 80) that load-balances to the pods'
port 9898. Pod IPs change; the Service name never does.

**`ingress.yaml`**: a rule for Traefik: "requests for host `demo-service.<domain>` go to Service `demo-service`".
Host names: `<service>-dev.<domain>`, `<service>-test.<domain>`, and `<service>.<domain>` for prod.

### 8.3 nip.io: DNS without buying a domain
`nip.io` is a free public DNS service: any name ending in `<IP>.nip.io` resolves to `<IP>`.
So `demo-service-dev.20.240.199.229.nip.io` → `20.240.199.229` (the master). Different host names, same IP;
Traefik uses the host name to pick the right environment. With a real domain later, only `envs/cluster.yaml` changes.

### 8.4 One environment's values file
```yaml
# envs/prod/demo-service/values.yaml
env: prod
replicas: 2
image:
  repository: ghcr.io/stefanprodan/podinfo
  tag: "6.17.0"     # <- the CI pipeline will change ONLY this line to deploy a new version
env_vars:
  PODINFO_UI_MESSAGE: "FitApp - PROD environment"
  PODINFO_UI_COLOR: "#1565c0"
```

---

## 9. The life of a request: from the browser to a pod

What happens when the professor opens `http://demo-service.20.240.199.229.nip.io`:

```
 1. Browser asks DNS: "demo-service.20.240.199.229.nip.io ?"  → nip.io answers 20.240.199.229
 2. Browser connects to 20.240.199.229 port 80
 3. Azure NSG of the master: port 80 from Internet → rule 120 ALLOW
 4. Packet arrives on k3s-master; ServiceLB hands it to Traefik
 5. Traefik reads the Host header → Ingress "demo-service" in namespace prod
 6. → Service "demo-service" (prod) → picks one READY pod (load balancing)
 7. If that pod is on k3s-worker-1, the packet goes through the Flannel tunnel over 10.0.1.0/24
 8. NetworkPolicy: source = Traefik (kube-system) → allowed
 9. podinfo answers: "FitApp - PROD environment", blue page
```

---

## 10. The 4 commands: up, stop, destroy, status

All in `fitapp-infra/scripts/`. They are thin wrappers around Terraform, Ansible and the Azure API.

| Command | What it does | Time | Cost afterwards |
|---|---|---|---|
| `./scripts/up.sh` | First run: bootstrap. Then: detect our IP → Terraform apply → start VMs if stopped → Ansible → status | 12–20 min from zero; ~5 min after a stop | ~$0.13/h |
| `./scripts/stop.sh` | **Deallocates** the VMs: no CPU billing; disks, IPs and the whole cluster are kept | ~2 min | ~$0.04/h (disks + IPs) |
| `./scripts/destroy.sh` | `terraform destroy`: deletes everything except the permanent bootstrap | ~5 min | ~$0 |
| `./scripts/status.sh` | VM power states, nodes, Argo CD pods | seconds | — |

`AUTO_APPROVE=1 ./scripts/up.sh` skips Terraform's "yes" confirmation.

Every run of `up.sh` **re-detects our public IP** and updates the firewall rule (mobile/4G connections change IP often).

Why the first build takes ~15 minutes: Azure needs 2–3 minutes per VM, and the full OS upgrade + reboot
takes several minutes. After a `stop`, everything is already installed, so `up.sh` only restarts and checks.

---

## 11. Problems we hit and how we solved them

Real problems, real fixes. Showing them is part of the work.

| Problem | Cause | Fix |
|---|---|---|
| "No Ubuntu machine available" in France Central | The **size** (B2s/B2ms) was not offered to our subscription; Ubuntu itself was fine | Checked quotas/SKUs with the CLI; moved to **B-series v2** in **Sweden Central** |
| B-series quota only 4 vCPU | Student subscription limit on the old family | Basv2 family has its own quota (10); total regional limit (6) still respected |
| ~$16 of credit gone before we started | An old Standard public IP left for months | Destroy deletes everything; nightly auto-shutdown; budget alert |
| Kali's `az` CLI crashed on most write commands (`No module named azure.mgmt.resource…`) | Broken Kali package | The bootstrap was written **in Terraform** instead of a bash script (better IaC anyway); Terraform only needs our login |
| `Error ensuring Resource Providers are registered` | Terraform tries to register ~70 Azure services by default; student subscriptions may not register some | Checked that the ones we use are registered; set `resource_provider_registrations = "none"` |
| `lookup api.ipify.org … no such host` | The home router's DNS failed for that site | The script detects the IP itself with 4 different services and retries |
| `kubectl` / pipeline blocked after a while | Our public IP changed (4G) and the firewall only allows the old one | Re-run `up.sh` (re-detects the IP, updates the NSG in seconds) |
| First network test showed dev → dev blocked | The NetworkPolicy controller needs ~1–2 s to register a brand-new pod | Test pods wait 3 s; real apps are unaffected |

---

## 12. Security summary

| Layer | Control | Where |
|---|---|---|
| Cloud network | Only 80/443 public; SSH + Kubernetes API only from the admin IP; workers closed to the internet; explicit deny rules | `network.tf` |
| Access | SSH keys only, no passwords, no root login, bastion (jump host) to reach workers | `vms.tf`, role `common`, inventory |
| OS | Full patching, automatic security updates, fail2ban, kernel hardening | role `common` |
| Boot integrity | Trusted Launch (Secure Boot + vTPM) | `vms.tf` |
| Secrets | Key Vault with RBAC; nodes read-only via managed identity; k3s token never logged or stored; kubeconfig and tfvars git-ignored | `keyvault.tf`, roles, `.gitignore` |
| Terraform state | No storage keys (Entra ID only), TLS 1.2+, versioning, soft delete, locking | `bootstrap/` |
| Kubernetes | Secrets encrypted at rest; API restricted by IP and certificates | k3s config |
| Workloads | Pod Security "restricted", non-root, read-only filesystem, no capabilities, seccomp, no service-account token | `platform/`, chart |
| Isolation | NetworkPolicies default-deny + same-env only; quotas per environment | `platform/` |
| Delivery | GitOps pull model: CI never gets cluster credentials; every change reviewed in git; self-heal undoes manual changes | Argo CD |
| Supply chain | Pinned versions everywhere (providers, k3s, Argo CD, images) | `versions.tf`, `group_vars`, values |
| Cost | Budget alerts, auto-shutdown, ephemeral infrastructure | `bootstrap/`, `vms.tf`, scripts |

---

## 13. Costs

| Item | Price |
|---|---|
| Master B2als_v2 | ~$0.039/h |
| Worker B2as_v2 | ~$0.078/h |
| 64 GB Standard SSD (each) | ~$0.007/h |
| Standard public IP (each) | ~$0.005/h |
| **Running platform (master + 1 worker)** | **~$0.13/h** (≈ $1 for an 8-hour day) |
| Stopped (disks + IPs only) | ~$0.04/h |
| Destroyed (state storage only) | a few cents per month |

---

## 14. What comes next

1. **CI pipeline (Azure DevOps)** for the auth-service: build → tests → security scans (secrets, SAST, dependencies, image) → push image → change the tag in `envs/dev/auth-service/values.yaml` → Argo CD deploys to dev.
2. **Promotion**: develop → main = copy the tag to `envs/test/…` (+ integration tests and DAST); manual approval → copy to `envs/prod/…`.
3. **Argo Rollouts** in prod: canary 10% → 25% → 50% → 100% with automatic rollback on errors.
4. **Platform services via GitOps**: PostgreSQL, RabbitMQ, Prometheus/Grafana/Loki, External Secrets (Key Vault), Kyverno policies, cert-manager (HTTPS).
5. **Infra pipeline**: Terraform plan on pull requests, apply after approval.

---

## 15. Questions the professor may ask

**Why not create the VMs in the Azure portal? It's faster.**
Once, maybe. But we rebuild the platform for every demo, teammates need the same setup, and we need proof of
what exists. With code, it's reproducible (same result every time), reviewable (PRs), versioned (git history)
and fast to rebuild (~15 min, one command). When one student account runs out of credit, we rebuild the same
platform on a teammate's account.

**What's the difference between Terraform and Ansible?**
Terraform creates cloud resources by talking to the Azure API. Ansible configures the inside of the machines over
SSH. Terraform builds the house; Ansible furnishes it.

**Why is there a public IP on the workers if they must be private?**
For **outbound** traffic only (updates, images). Their firewall refuses every inbound connection from the internet.
A NAT Gateway would be cleaner but costs ~$32/month.

**How does Ansible reach the workers then?**
Through the master, used as a jump host (bastion), over the private network.

**Why k3s and not "real" Kubernetes?**
k3s *is* real Kubernetes: certified by the CNCF, same API. It is lighter and cheaper, which matters with 4–8 GB
VMs and student credit.

**Why are dev, test and prod on the same cluster?**
Budget. In a company they'd be separate clusters. We compensate with Pod Security, quotas and NetworkPolicies, and
we demonstrated that dev cannot reach prod.

**How does a new version get deployed?**
The CI pipeline builds an image and changes one line (the tag) in the gitops repo. Argo CD sees the commit and
updates the cluster. Nobody runs `kubectl apply`, and the pipeline never has cluster credentials.

**What happens if someone changes something directly in the cluster?**
Argo CD's self-heal puts it back as git says, within minutes. Live demo: delete a pod or scale a deployment by hand,
and watch Argo CD restore it.

**What happens if a VM dies?**
Prod has 2 replicas on 2 different machines, so the service keeps answering. Kubernetes reschedules the lost pods.
Terraform + Ansible can rebuild the machine.

**How do you roll back?**
`git revert` the commit in the gitops repo; Argo CD applies the previous version. (Next step: Argo Rollouts does it
automatically when a canary shows errors.)

**Where are the secrets?**
Not in git. Infrastructure secrets (SSH key, kubeconfig) stay on the admin laptop; the k3s token is read at runtime and
never logged; application secrets will go to Azure Key Vault and be synced into Kubernetes by External Secrets.

**How much does it cost?**
About $0.13 per hour while running, ~$1 per demo day; ~$0 when destroyed.

---

## 16. Glossary

| Term | Meaning |
|---|---|
| **IaC** | Infrastructure as Code: infrastructure described in files, created by tools |
| **Terraform state** | Terraform's memory of what it created |
| **Provider** | Terraform plugin for a platform (here `azurerm` for Azure) |
| **Resource group** | A folder of Azure resources; deleting it deletes its content |
| **VNet / subnet** | Private network in Azure / a slice of it |
| **CIDR** (`10.0.1.0/24`) | Notation for a range of IP addresses (`/24` = 256 addresses) |
| **NSG** | Network Security Group: Azure firewall rules |
| **NIC** | Network interface card of a VM |
| **Managed identity** | An Azure identity given to a VM, used without passwords |
| **Trusted Launch** | Secure Boot + virtual TPM: only trusted boot code can run |
| **Bastion / jump host** | A machine used as the single entry point to reach private machines |
| **Idempotent** | Running it again gives the same result; safe to repeat |
| **Playbook / role** | Ansible's list of tasks / a reusable group of tasks |
| **Kubernetes node** | A machine of the cluster |
| **Control plane** | The "brain" of Kubernetes (API server, scheduler, controllers) |
| **Pod** | The smallest unit Kubernetes runs: one or more containers |
| **Deployment** | Keeps N replicas of a pod running and handles updates |
| **Service** | Stable internal name + load balancing to pods |
| **Ingress / ingress controller** | HTTP routing rule from outside to a Service / the program that applies it (Traefik) |
| **Namespace** | A logical partition of the cluster (our environments) |
| **NetworkPolicy** | Firewall rules between pods |
| **ResourceQuota** | Maximum resources a namespace may use |
| **Pod Security Standard** | Built-in Kubernetes rules about what pods may do (restricted = strictest) |
| **Probe** (liveness / readiness) | Health checks: restart if dead / no traffic until ready |
| **Helm chart** | Templated Kubernetes YAML with values |
| **GitOps** | Git is the source of truth; a robot keeps the cluster equal to git |
| **Argo CD Application** | "Keep this folder of this repo applied to this namespace" |
| **ApplicationSet** | A generator that creates many Applications automatically |
| **Sync / prune / self-heal** | Apply git / delete what was removed from git / undo manual changes |
| **nip.io** | Free wildcard DNS: `name.<IP>.nip.io` → `<IP>` |
