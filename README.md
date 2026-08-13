# 2-Tier Architecture on AWS

A complete, hands-on build of a highly available 2-tier web architecture on AWS — covering networking, compute, static content delivery, and monitoring/alerting. Written as a full step-by-step console walkthrough for beginners, based on an actual build-and-debug session.

> **Note:** Amazon Route 53 (DNS) is intentionally excluded from this build since it's a paid service. The application is accessed directly via the Application Load Balancer's public DNS name and the CloudFront distribution domain name.

---

## Table of Contents

1. [Architecture Overview](#Architecture Overview)
2. [Prerequisites](#prerequisites)
3. [Cost Notes](#cost-notes)
4. [Step 1 — Create the VPC](#step-1--create-the-vpc)
5. [Step 2 — Verify Subnets and Route Tables](#step-2--verify-subnets-and-route-tables)
6. [Step 3 — Create Security Groups](#step-3--create-security-groups)
7. [Step 4 — Create the S3 Bucket](#step-4--create-the-s3-bucket-static-content)
8. [Step 5 — Create the CloudFront Distribution](#step-5--create-the-cloudfront-distribution)
9. [Step 6 — Create a Launch Template (Ubuntu)](#step-6--create-a-launch-template-ubuntu)
10. [Step 7 — Create the Application Load Balancer](#step-7--create-the-application-load-balancer)
11. [Step 8 — Create the Auto Scaling Group](#step-8--create-the-auto-scaling-group)
12. [Step 9 — Create an SNS Topic](#step-9--create-an-sns-topic)
13. [Step 10 — Create CloudWatch Alarms](#step-10--create-cloudwatch-alarms)
14. [Step 11 — Connecting to Private-Subnet EC2 Instances](#step-11--connecting-to-private-subnet-ec2-instances)
15. [Step 12 — End-to-End Testing](#step-12--end-to-end-testing)
16. [Cleanup](#cleanup)
17. [Troubleshooting Log](#troubleshooting-log)
18. [Files in this Repo](#files-in-this-repo)
19. [Architecture-to-Console Mapping](#architecture-to-console-mapping)

---

## Architecture Overview

Architecture Diagram:https://github.com/jesswinanto1/aws-2tier-architecture/blob/main/aws-2tier-architecture-diagram.png

| Component | Purpose | Placement |
|---|---|---|
| **Amazon S3** | Stores static content (images, CSS, JS, HTML) | N/A (regional, origin for CloudFront) |
| **Amazon CloudFront** | Global CDN — delivers and caches static content from S3 at edge locations worldwide | Global service |
| **VPC** | Isolated network (`10.0.0.0/16`) with 2 public + 2 private subnets across 2 Availability Zones | Regional |
| **Internet Gateway (IGW)** | Allows public subnet resources to send/receive traffic to the internet | Attached to VPC |
| **NAT Gateway** | Allows private-subnet instances outbound internet access (e.g. `apt update`) without being publicly reachable | Public subnet |
| **Application Load Balancer (ALB)** | Distributes incoming HTTP traffic across EC2 instances in both AZs | Public subnets |
| **Auto Scaling Group (ASG)** | Automatically launches/terminates EC2 instances based on CPU demand | Private subnets |
| **EC2 Instances (Ubuntu)** | Web/application tier, running Apache | Private subnets |
| **Amazon CloudWatch** | Monitors metrics (CPU, network in, status checks) | N/A |
| **CloudWatch Alarms** | Triggers when a threshold (e.g. CPU > 70%) is breached | N/A |
| **Amazon SNS** | Sends email notifications to the operations team when an alarm fires | N/A |

**Traffic flow:**
```
User → CloudFront (static) → S3
User → ALB (dynamic) → Target Group → EC2 instances (private subnets, via ASG)
EC2/ASG metrics → CloudWatch → CloudWatch Alarm → SNS → Email (Operations Team)
```

---

## Prerequisites

- An AWS account (a mix of free-tier and paid resources are used — see [Cost Notes](#cost-notes))
- Access to the AWS Management Console (this guide is console-only, no CLI/Terraform required)
- One AWS region selected and used consistently for every step (e.g. `ap-south-1` — Mumbai)
- A valid email address you can access, for SNS alarm notifications
- Basic comfort using a web browser and following numbered instructions — no prior AWS experience assumed

---

## Cost Notes

| Resource | Free tier? | Notes |
|---|---|---|
| VPC, Subnets, IGW, Route Tables, Security Groups | Free | No charge for these constructs themselves |
| **NAT Gateway** | **Not free** | ~$0.045/hr + per-GB data processing, charged even when idle. Biggest cost risk in this build. |
| EC2 `t2.micro` / `t3.micro` | Free tier eligible | Within free tier limits (750 hrs/month for 12 months on new accounts) |
| **Application Load Balancer** | **Not free** | ~$0.0225/hr + LCU charges, charged even with no traffic |
| S3 | Free tier eligible | 5GB storage free tier |
| CloudFront | Free tier eligible | 1TB data transfer out free tier (first 12 months) |
| CloudWatch Alarms | Free tier eligible | First 10 alarms free |
| SNS | Free tier eligible | First 1,000 email notifications free/month |

**Recommendation:** If this is a learning project rather than a production deployment, complete the [Cleanup](#cleanup) section as soon as you're done testing to avoid ongoing charges — especially the NAT Gateway and ALB.

---

## Step 1 — Create the VPC

1. Open the AWS Console, search for **VPC**, and open the VPC dashboard.
2. Click **Your VPCs** in the left sidebar, then **Create VPC**.
3. At the top, choose **VPC and more** — this wizard auto-creates subnets, route tables, and an Internet Gateway in one step, which is far less error-prone than building each piece manually.
4. Configure the following:
   - **Name tag auto-generation**: `twotier`
   - **IPv4 CIDR block**: `10.0.0.0/16`
   - **IPv6 CIDR block**: No IPv6 CIDR block
   - **Tenancy**: Default
   - **Number of Availability Zones (AZs)**: `2`
   - **Number of public subnets**: `2`
   - **Number of private subnets**: `2`
   - **NAT gateways**: `1 per AZ` for full redundancy, or `In 1 AZ` to halve the cost for a demo build
   - **VPC endpoints**: None
   - **DNS options**: leave both "Enable DNS hostnames" and "Enable DNS resolution" checked (default)
5. Review the summary diagram AWS shows on the right — it should visually match your target architecture's networking layer.
6. Click **Create VPC**. This takes 1–2 minutes to fully provision all resources.

**What this creates automatically:**
- 1 VPC (`10.0.0.0/16`)
- 2 public subnets (one per AZ), each auto-assigned a `/20` or similar CIDR block
- 2 private subnets (one per AZ)
- 1 Internet Gateway, attached to the VPC
- 1 (or 2) NAT Gateway(s) in the public subnet(s), each with an Elastic IP
- 1 public route table (associated with both public subnets)
- 1 or 2 private route table(s) (associated with the private subnets)

---

## Step 2 — Verify Subnets and Route Tables

Confirming the wizard built things correctly before moving on saves debugging time later.

1. In the VPC console left sidebar, click **Subnets**.
2. Filter by your VPC (`twotier-vpc`) if needed. Confirm you see **4 subnets total**:
   - 2 tagged something like `twotier-subnet-public1-<az>` and `twotier-subnet-public2-<az>`
   - 2 tagged `twotier-subnet-private1-<az>` and `twotier-subnet-private2-<az>`
   - Confirm they're spread across **2 different Availability Zones** (e.g., `ap-south-1a` and `ap-south-1b`) — this is what gives the architecture its high availability.
3. Click **Route Tables** in the left sidebar.
4. Open the **public route table** → **Routes** tab. Confirm a route exists: `0.0.0.0/0` → target is the **Internet Gateway** (`igw-xxxxxxxx`).
5. Open the **private route table** → **Routes** tab. Confirm a route exists: `0.0.0.0/0` → target is the **NAT Gateway** (`nat-xxxxxxxx`).
6. Click **Internet Gateways** in the left sidebar. Confirm one exists and its **State** is `Attached` to `twotier-vpc`.
7. Click **NAT Gateways** in the left sidebar. Confirm the state is `Available` (this can take a few minutes after VPC creation).

If any of these don't match, the safest fix is usually to delete the VPC and re-run the wizard rather than patching pieces manually.

---

## Step 3 — Create Security Groups

Security groups act as virtual firewalls. This build uses two, layered so that only the ALB can reach the EC2 instances — the instances are never directly exposed to the public internet.

### A. ALB Security Group

1. VPC console → **Security Groups** (left sidebar) → **Create security group**.
2. **Security group name**: `alb-sg`
3. **Description**: `Allows public HTTP/HTTPS traffic to the ALB`
4. **VPC**: `twotier-vpc`
5. **Inbound rules** → **Add rule**:
   - Type: **HTTP**, Port: `80`, Source: **Anywhere-IPv4** (`0.0.0.0/0`)
   - (Optional, for later HTTPS setup) Type: **HTTPS**, Port: `443`, Source: **Anywhere-IPv4**
6. **Outbound rules**: leave default (Allow all traffic)
7. Click **Create security group**.

### B. EC2 Security Group

1. Create another security group: name `ec2-sg`, VPC `twotier-vpc`.
2. **Description**: `Allows HTTP from ALB only, SSH from VPC CIDR for debugging`
3. **Inbound rules**:
   - Type: **HTTP**, Port: `80`, Source: **Custom** → select the `alb-sg` security group (not an IP range) — this ensures only traffic routed through the ALB can reach port 80 on the instances.
   - Type: **SSH**, Port: `22`, Source: **Custom** → `10.0.0.0/16` (the VPC CIDR) — this allows SSH only from within the VPC, e.g. via an EC2 Instance Connect Endpoint (see Step 11), not from the public internet.
4. **Outbound rules**: leave default (Allow all traffic) — instances need this to reach the NAT Gateway for updates.
5. Click **Create security group**.

---

## Step 4 — Create the S3 Bucket (Static Content)

1. AWS Console → search **S3** → **Create bucket**.
2. **Bucket name**: must be globally unique across all of AWS, e.g. `twotier-static-<yourname>-2026`.
3. **AWS Region**: same region as your VPC.
4. **Object Ownership**: leave as **ACLs disabled** (default, recommended).
5. **Block Public Access settings for this bucket**: leave **all four boxes checked** (Block all public access) — CloudFront will access the bucket privately via Origin Access Control (OAC), so the bucket itself never needs to be public. This is the modern, secure pattern (avoid the older approach of making S3 buckets public).
6. **Bucket Versioning**: Disable (not needed for this demo).
7. **Default encryption**: leave as **Amazon S3 managed keys (SSE-S3)** (default).
8. Click **Create bucket**.
9. Open the bucket → **Objects** tab → **Upload** → **Add files** → select your `index.html` (see [Files in this Repo](#files-in-this-repo)) → **Upload**.

---

## Step 5 — Create the CloudFront Distribution

CloudFront is a **global** service — you won't see a region selector for it the way you do for EC2/VPC/S3. It automatically deploys your content to edge locations worldwide; you only pick a region for the **origin** (your S3 bucket), not for CloudFront itself.

1. AWS Console → search **CloudFront** → **Distributions** → **Create distribution**.
2. **Distribution type**: select **Single website or app** (the other option, "Multi-tenant architecture," is for SaaS platforms serving many customers from one distribution — not relevant here).

**Specify origin section:**
3. **Origin domain**: click the field, select your S3 bucket from the dropdown (e.g. `twotier-static-yourname-2026.s3.ap-south-1.amazonaws.com`).
4. **Origin path**: leave blank (the greyed-out `/path` text is just a placeholder example, not a value to fill in).
5. **Name**: auto-fills based on the bucket — leave as is.
6. **Allow private S3 bucket access to CloudFront**: leave this checkbox **checked** (recommended). This is the modern replacement for the older manual "create OAC, copy bucket policy, paste into S3" flow — AWS now handles the bucket policy update automatically in the background.
7. **Origin settings**: keep **Use recommended origin settings** selected.
8. **Cache settings**: keep **Use recommended cache settings tailored to serving S3 content** selected.
9. Click **Next**.

**Enable security section (Step 3 of the wizard):**
10. **Web Application Firewall (WAF)**: select **Do not enable security protections** — WAF adds cost and isn't needed for a static content demo.
11. Click **Next**.

**Review and create:**
12. Scroll through the summary, confirming the origin is your S3 bucket and viewer protocol policy is set to redirect HTTP to HTTPS.
13. Click **Create distribution**.
14. Status will show **Deploying** — wait 3–5 minutes for it to change to **Enabled** (refresh the page to check).

**Set the default root object (required for the bare domain to work):**
15. Once created, click into the distribution → **General** tab → find **Settings** → click **Edit**.
16. Find **Default root object** and set it to exactly: `index.html`
17. Click **Save changes**. Wait a couple of minutes for redeployment.

**Test it:**
18. Copy the **Distribution domain name** (e.g. `d1a2b3c4d5e6f7.cloudfront.net`) from the top of the distribution page.
19. Paste it into a browser. You should see your uploaded `index.html` content.

> ⚠️ **Known issue — AccessDenied error:** If you get an XML `AccessDenied` error when loading the bare CloudFront domain, the #1 cause is a mismatched **Default root object**. The bucket policy can be perfectly correct (auto-generated, referencing `cloudfront.amazonaws.com` and your distribution's ARN) and you'll *still* get this error if the Default root object field doesn't exactly match your uploaded filename, character for character (e.g. `Jesswinindex.html` vs the actual file `index.html`). Always double-check this field first when troubleshooting a blank/denied CloudFront page.

---

## Step 6 — Create a Launch Template (Ubuntu)

The Launch Template defines the "blueprint" every Auto Scaling Group instance will be built from — AMI, instance type, security group, and startup script.

1. AWS Console → **EC2** → left sidebar, under **Instances**, click **Launch Templates** → **Create launch template**.
2. **Launch template name**: `twotier-launch-template`
3. **Template version description**: `Ubuntu web tier v1`
4. Leave the "Auto Scaling guidance" checkbox/tip as-is — no action needed.

**Application and OS Images (AMI):**
5. Under the Quick Start tab, click the **Ubuntu** tile.
6. In the AMI dropdown, select **Ubuntu Server 22.04 LTS** (or 24.04 LTS) — confirm it's labeled **Free tier eligible**.

**Instance type:**
7. Select `t2.micro` or `t3.micro` — confirm "Free tier eligible" is shown.

**Key pair (login):**
8. Click the **Key pair** dropdown.
   - If you have one, select it.
   - Otherwise, click **Create new key pair** → name it `twotier-key` → Key pair type: RSA → Private key format: `.pem` (Mac/Linux) or `.ppk` (PuTTY on Windows) → **Create key pair** (downloads automatically — save it, it cannot be re-downloaded).
   - This is optional if you'll only use EC2 Instance Connect Endpoint (Step 11), but selecting one is a good habit.

**Network settings:**
9. **Subnet**: leave as **Don't include in launch template** — the Auto Scaling Group assigns subnets in Step 8.
10. **Firewall (security groups)**: select **Select existing security group** → choose `ec2-sg`. Deselect "default" if it's pre-checked.

**Storage (volumes):**
11. Leave the default root volume (typically 8 GiB, gp3) — no changes needed.

**Advanced details → User data:**
12. Expand **Advanced details**, scroll to the **User data** box near the bottom, and paste:
    ```bash
    #!/bin/bash
    apt update -y
    apt install -y apache2
    systemctl start apache2
    systemctl enable apache2
    echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
    ```
    This script runs automatically the first time each instance boots — it installs Apache and creates a basic test page showing the instance's hostname, which is useful for visually confirming the ALB is load-balancing across multiple instances later.

13. Click **Create launch template**.
14. On the confirmation screen, you do **not** need to click "Create Auto Scaling group from this template" yet — that happens separately in Step 8, after the Load Balancer exists in Step 7.

> **Why Ubuntu uses `apt` and not `yum`:** Amazon Linux uses the `yum`/`dnf` package manager, while Ubuntu/Debian-based systems use `apt`. If you copy a user-data script written for Amazon Linux onto an Ubuntu AMI (or vice versa), it will fail silently — always match the script's package manager to the chosen AMI.

---

## Step 7 — Create the Application Load Balancer

1. **EC2** → left sidebar, under **Load Balancing**, click **Load Balancers** → **Create load balancer**.
2. Choose **Create** under **Application Load Balancer** (the other options — Network, Gateway, Classic — aren't used here).

**Basic configuration:**
3. **Load balancer name**: `twotier-alb`
4. **Scheme**: **Internet-facing**
5. **IP address type**: **IPv4**

**Network mapping:**
6. **VPC**: `twotier-vpc`
7. **Mappings**: check the boxes for **both Availability Zones**. For each AZ, select the corresponding **public subnet** in the dropdown (the ALB itself must live in public subnets to be internet-facing, even though the EC2 instances behind it live in private subnets).

**Security groups:**
8. Deselect the default security group if pre-checked.
9. Select `alb-sg`.

**Listeners and routing:**
10. Default listener: **HTTP : 80** (leave as is).
11. In the **Default action** dropdown, click **Create target group** to open the sub-flow:
    - **Target type**: **Instances**
    - **Target group name**: `twotier-tg`
    - **Protocol / Port**: HTTP / 80
    - **VPC**: `twotier-vpc`
    - **Protocol version**: HTTP1
    - **Health checks**: Protocol HTTP, Path `/`, leave advanced thresholds at default (healthy threshold 5, interval 30s)
    - Click **Next**
    - On "Register targets," **skip** — don't select any instances (none exist yet; the ASG registers them automatically)
    - Click **Create target group**
12. Back on the ALB creation page, select `twotier-tg` in the **Default action** dropdown.
13. Review the summary, then click **Create load balancer**.
14. Wait 2–3 minutes for state to change from **Provisioning** to **Active**.
15. Click into `twotier-alb` and copy its **DNS name** (e.g. `twotier-alb-123456789.ap-south-1.elb.amazonaws.com`) — save this for testing.

> **Expected state right now:** loading the ALB's DNS name in a browser will show a **503 Service Unavailable** error. This is normal — no EC2 instances are registered with the target group yet. That's resolved in Step 8.

---

## Step 8 — Create the Auto Scaling Group

**Step 1: Choose launch template**
1. **EC2** → left sidebar, under **Auto Scaling**, click **Auto Scaling Groups** → **Create Auto Scaling group**.
2. **Name**: `twotier-asg`
3. **Launch template**: `twotier-launch-template`, Version: **Default** (or Latest)
4. Click **Next**

**Step 2: Choose instance launch options**
5. **VPC**: `twotier-vpc`
6. **Availability Zones and subnets**: deselect any public subnets if pre-selected; select **both private subnets** — this places EC2 instances in the private subnet tier, matching the diagram.
7. Leave remaining settings default.
8. Click **Next**

**Step 3: Configure advanced options**
9. **Load balancing**: **Attach to an existing load balancer** → **Choose from your load balancer target groups** → select `twotier-tg`.
10. **Health checks**: check **Turn on Elastic Load Balancing health checks** (in addition to default EC2 checks — this makes the ASG replace instances that fail ALB-level health checks, not just EC2-level failures).
11. **Health check grace period**: leave default (300 seconds).
12. **Additional settings**: skip detailed CloudWatch monitoring to avoid extra cost, unless desired.
13. Click **Next**

**Step 4: Configure group size and scaling**
14. **Desired capacity**: `2`
15. **Minimum capacity**: `2`
16. **Maximum capacity**: `4`
17. **Scaling policies**: **Target tracking scaling policy**
    - Policy name: `cpu-target-tracking` (or leave default)
    - Metric type: **Average CPU utilization**
    - Target value: `50`
    - Instance warmup: leave default (300 seconds)
18. Leave **Instance maintenance policy** default.
19. Click **Next**

**Step 5: Add notifications** — skip (CloudWatch Alarms + SNS are configured separately in Steps 9–10). Click **Next**.

**Step 6: Add tags** — optionally add `Name` = `twotier-instance` to make instances easier to identify in the EC2 list. Click **Next**.

**Step 7: Review**
20. Confirm: launch template, VPC, private subnets, target group `twotier-tg`, capacity 2/2/4, target tracking at 50% CPU.
21. Click **Create Auto Scaling group**.

**Verify:**
22. Wait 2–3 minutes. **EC2 → Instances** should show 2 new "Running" instances tagged with the ASG.
23. **EC2 → Target Groups → `twotier-tg` → Targets** tab — both should eventually show **Healthy**.
24. Reload the ALB's DNS name in a browser — you should now see **"Hello from `<hostname>`"** instead of the earlier 503 error. Refreshing repeatedly should occasionally show a different hostname as the ALB load-balances between the two instances.

---

## Step 9 — Create an SNS Topic

1. AWS Console → search **SNS** → **Topics** → **Create topic**.
2. **Type**: **Standard**
3. **Name**: `twotier-alerts`
4. Leave Display name, Encryption, Access policy, Delivery retry policy, and Delivery status logging at their defaults.
5. Click **Create topic**.
6. On the topic detail page, click **Create subscription**.
7. **Protocol**: **Email**
8. **Endpoint**: your email address
9. Click **Create subscription**.
10. Check your email inbox for a message from AWS Notifications titled "AWS Notification - Subscription Confirmation" and click **Confirm subscription** inside it.
11. Back in the SNS console, refresh the **Subscriptions** tab — status should change from "Pending confirmation" to **Confirmed**.

> **Important:** if the subscription isn't confirmed, CloudWatch alarms will still technically "fire" later, but no email will ever arrive. Confirm this before moving on.

---

## Step 10 — Create CloudWatch Alarms

**Step 1: Specify metric and conditions**
1. AWS Console → **CloudWatch** → **Alarms** → **All alarms** → **Create alarm**.
2. Click **Select metric** → **EC2** → **By Auto Scaling Group**.
3. Find the `twotier-asg` row with metric **CPUUtilization**, check its box, click **Select metric**.
4. **Statistic**: Average. **Period**: 5 minutes (or 1 minute for faster testing).
5. **Conditions**: Threshold type **Static** → "Whenever CPUUtilization is..." **Greater** → than `70`.
6. Leave additional configuration (datapoints to alarm, missing data treatment) at default.
7. Click **Next**.

**Step 2: Configure actions**
8. **Alarm state trigger**: **In alarm**.
9. **Select an SNS topic** → **Select an existing SNS topic** → choose `twotier-alerts`.
10. (Optional) Add a second action for the **OK** state, also pointing to `twotier-alerts`, to get notified when CPU returns to normal.
11. Click **Next**.

**Step 3: Add name and description**
12. **Alarm name**: `twotier-cpu-high`
13. **Alarm description**: `Triggers when average CPU exceeds 70%`
14. Click **Next**.

**Step 4: Preview and create**
15. Review the summary — metric CPUUtilization on `twotier-asg`, threshold >70, action → `twotier-alerts`.
16. Click **Create alarm**.

**Verify:**
17. The alarm's state initially shows **Insufficient data**, then settles to **OK** (green) once metric data arrives — normal, since idle instances have low CPU.

---

## Step 11 — Connecting to Private-Subnet EC2 Instances

Since ASG instances live in private subnets by design, they have **no public IPv4 address** — this is expected, not a misconfiguration. Direct SSH from a local machine won't work. Instead, use **EC2 Instance Connect Endpoint**, AWS's browser-based method for securely reaching private instances with no public IP and no bastion host required.

**A. Create the Instance Connect Endpoint (one-time setup)**
1. **EC2 → Instances** → select an instance → **Connect** → **EC2 Instance Connect** tab.
2. If no endpoint exists, click **Create EC2 Instance Connect Endpoint**.
3. Configure:
   - **VPC**: `twotier-vpc`
   - **Subnet**: one of the private subnets
   - **Security group**: ensure `ec2-sg` allows inbound SSH (22) from the VPC CIDR (`10.0.0.0/16`) — see Step 3B.
4. Click **Create endpoint**. Wait 1–2 minutes for it to become **Available**.

**B. Confirm the EC2 security group allows this**
5. **EC2 → Security Groups → `ec2-sg` → Inbound rules → Edit inbound rules**.
6. Confirm/add: Type **SSH (22)**, Source **Custom** → `10.0.0.0/16`.
7. Save rules.

**C. Connect**
8. **EC2 → Instances** → select instance → **Connect → EC2 Instance Connect** tab.
9. Username auto-fills as `ubuntu` (matches the Ubuntu AMI).
10. Click **Connect** — a browser-based terminal opens directly into the instance.

---

## Step 12 — End-to-End Testing

1. **Static content path**: load the CloudFront domain (`dxxxxxxx.cloudfront.net`) → should serve the S3-hosted `index.html`.
2. **Dynamic/app path**: load the ALB's DNS name → should route to a healthy EC2 instance, showing `Hello from <hostname>`, rotating between instances on refresh.
3. **Scaling and alerting test** (optional but recommended): connect to an instance via EC2 Instance Connect Endpoint (Step 11) and run:
   ```bash
   sudo apt install -y stress
   stress --cpu 2 --timeout 400
   ```
4. Wait 5–10 minutes and watch:
   - **CloudWatch → Alarms → `twotier-cpu-high`** should transition to **In alarm** (red).
   - Your email inbox should receive the SNS notification.
   - Depending on your max capacity setting, the Auto Scaling Group may also launch additional instances — watch the **Activity** tab under the ASG.

---

## Cleanup

Delete resources in this order to avoid dependency errors and stop ongoing charges — this is important since NAT Gateway and ALB are billed hourly even when idle:

1. **Auto Scaling Group** (`twotier-asg`) — delete first; this terminates the EC2 instances automatically.
2. **Load Balancer** (`twotier-alb`) → then delete the **Target Group** (`twotier-tg`) separately.
3. **EC2 Instance Connect Endpoint** (if created).
4. **NAT Gateway** — the single biggest idle-cost risk if left running.
5. **CloudFront distribution** — select it → **Disable** first → wait for it to finish deploying → then **Delete**.
6. **S3 bucket** — empty it (delete the `index.html` object), then delete the bucket itself.
7. **CloudWatch Alarm** (`twotier-cpu-high`).
8. **SNS topic** (`twotier-alerts`).
9. **VPC** (`twotier-vpc`) — delete last; this cleans up subnets, route tables, and the Internet Gateway automatically since the wizard created them together.


## Files in this Repo

### `index.html`
Simple static test page served from S3 via CloudFront.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>2-Tier AWS Architecture</title>
<style>
  body { font-family: Arial, sans-serif; background: #f4f6f8; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .card { background: white; padding: 40px 60px; border-radius: 10px; box-shadow: 0 4px 12px rgba(0,0,0,0.1); text-align: center; }
  h1 { color: #232f3e; }
  p { color: #555; }
  .badge { display: inline-block; margin-top: 15px; padding: 6px 14px; background: #ff9900; color: white; border-radius: 20px; font-size: 14px; }
</style>
</head>
<body>
  <div class="card">
    <h1>Hello from Amazon S3 + CloudFront</h1>
    <p>This static page is served through CloudFront and stored in S3.</p>
    <span class="badge">2-Tier AWS Architecture Demo</span>
  </div>
</body>
</html>
```

### `user-data.sh` (used in the EC2 Launch Template)
```bash
#!/bin/bash
apt update -y
apt install -y apache2
systemctl start apache2
systemctl enable apache2
echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
```

---

## Architecture-to-Console Mapping

| Diagram Element | AWS Console Location |
|---|---|
| VPC, Public/Private Subnets, Internet Gateway, NAT Gateway | VPC → "VPC and more" wizard |
| Auto Scaling (arrows in diagram) | EC2 → Auto Scaling Groups |
| EC2 Instances (Web/Application Tier) | EC2 → Launch Templates + Auto Scaling Groups → Instances |
| Application Load Balancer | EC2 → Load Balancers |
| Amazon S3 (Static Content) | S3 |
| Amazon CloudFront | CloudFront → Distributions |
| Amazon CloudWatch / CloudWatch Alarms | CloudWatch → Alarms |
| Amazon SNS | SNS → Topics |
| Operations Team (Notifications) | Confirmed email inbox subscribed to the SNS topic |

---

