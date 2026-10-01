# librefs object storage

S3-compatible object storage for librefs, built on [SeaweedFS](https://github.com/seaweedfs/seaweedfs) 4.47 (Apache-2.0).

Docker Compose runs the storage processes. systemd only starts that Compose stack on boot. The data itself sits on a normal disk directory, not in a Docker volume.

## Why this shape

SeaweedFS is a maintained open-source object store with an S3 API. MinIO Community Edition was archived in April 2026 and no longer ships patches, so it is the wrong base for a new production system.

Compose fits a single storage host: one file, pinned image, health checks, and bind-mounted data. A systemd unit is the right add-on so the host brings the stack up after reboot. Running `weed` itself under systemd is the better layout later, on bare-metal machines where you do not want a container runtime in front of the disks.

Ceph RGW is the other serious open-source option, and it belongs under `cephadm` (systemd), not Compose. Use it when you have a storage team and multi-node disk clusters. This stack is the production default until that is true.

## The four containers

An upload hits `filer` on port 8333. The filer records the object name in its own index, asks `master` which volume should hold the bytes, and `volume` writes those bytes to disk. `render-s3-config` is not on that path. `docker ps` shows three containers up (`master`, `volume`, `filer`). The fourth has already exited on purpose.

`admin` is a fifth container, added later. It is the browser UI. It does not store objects. Its role is in [Web UI](#web-ui).

### `render-s3-config`

Runs once at startup, writes `$DATA_DIR/config/s3.json`, and exits. That file is the global admin identity: `S3_ACCESS_KEY` and `S3_SECRET_KEY` from `.env`, with permission to create buckets and to read and write every bucket. The file is mode `600` and owned by the SeaweedFS user inside the image. The filer mounts it read-only and loads it as a static identity. The key is not left in the filer's environment.

When `docker ps` no longer lists this container, the write succeeded. Recreate it only to rotate that admin key:

```sh
docker compose up -d --force-recreate render-s3-config filer
```

### `master`

Keeps the map of volumes: which volume ids exist, which volume server holds them, and the replication rule. On this stack the rule is `000`, one copy of each object. It also hands out volume ids when a new object needs a place to land.

It does not store object bytes. SeaweedFS treats this map as soft state and can rebuild it from the volume server after a restart. Losing `$DATA_DIR/master` is recoverable. While the master is down, new uploads pause; bytes already on disk stay where they are.

Its HTTP port stays on the internal `librefs-storage` network. It is not published on the host.

### `volume`

Stores the object bytes in large volume files under `$DATA_DIR/volume`. This is the directory that backups must cover. One volume server means one copy. A second container on the same disk does not add another copy.

The index of those volume files is leveldb, so a large disk does not have to keep the whole index in RAM. Background compaction is capped at 64 MB/s. When free space on the filesystem drops below 10%, the volume server marks itself read-only and new writes stop.

Losing this directory loses the files. A restart reads the same files back.

### `filer`

Two jobs in one process, which is the layout SeaweedFS recommends. The metadata store maps bucket name and object key to a volume id. The S3 API on port 8333 is the only port published to the host (`S3_BIND`, default `127.0.0.1`).

Metadata is local leveldb under `$DATA_DIR/filer`. Losing that directory loses the index even when the volume files are still on disk: the bytes are there, and nothing can name them. Back up `volume` and `filer` together.

Port 8333 is not a website. A browser sends an unsigned request, so `http://<host>:8333/` returns XML `AccessDenied`. That response means the gateway is up and a key is required.

| Container | Stays running | Disk directory | If it is gone |
| --- | --- | --- | --- |
| `render-s3-config` | No. Exits after `s3.json` is written. | `$DATA_DIR/config` | No effect, once the key file exists. |
| `master` | Yes | `$DATA_DIR/master` | New uploads pause. The directory can be rebuilt. |
| `volume` | Yes | `$DATA_DIR/volume` | The object bytes are unavailable. Losing the directory loses the files. |
| `filer` | Yes | `$DATA_DIR/filer` | The S3 API is down. Losing the directory loses the bucket index. |

Anonymous usage telemetry is off. Master, volume, and the filer's metadata port are only on the `librefs-storage` network.

## Is this safe and reliable in production

Safe for a private service on one host: clients must present the access key, the master and volume ports are not on the host network, the image is pinned to SeaweedFS 4.47, and a full disk stops new writes at 10% free instead of filling the filesystem.

Reliable across process crashes. Compose restarts `master`, `volume`, and `filer` unless you stop them. A reboot is covered by the systemd unit. A restarted volume server reads its own files back.

Reliable across a lost disk only if you have a backup of `$DATA_DIR/volume` and `$DATA_DIR/filer` taken together. Replication is `000`, so this host keeps a single copy. Host failure, disk failure, or deleting `DATA_DIR` is data loss until you restore those two directories. A second container on the same disk does not add a copy.

That is a normal production setup for one application server with backups and a restore drill. It is not a highly available storage cluster. Availability of the API equals availability of this machine. Add a volume server on another machine and switch replication to `010` when an outage of this host must not lose the only copy. Until that second disk exists, the backup is the second copy.

## Where the bytes are stored

Every data path in `docker-compose.yml` is a bind mount of a host directory. There is no Docker named volume. `docker compose down` removes containers and leaves the directory in place.

`DATA_DIR` in `.env` is that directory. Unset, it is `./data` next to the compose file. For production, point it at a filesystem on its own disk. See [Dedicated disk](#dedicated-disk).

| Host path | What is stored there |
| --- | --- |
| `$DATA_DIR/volume` | Object bytes. Back this up. |
| `$DATA_DIR/filer` | Bucket index. Back this up with `volume`. |
| `$DATA_DIR/master` | Volume map. SeaweedFS can rebuild it. |
| `$DATA_DIR/config` | `s3.json`, the global admin key. |
| `$DATA_DIR/admin` | Admin UI state, not object data. |

## Dedicated disk

`DATA_DIR` should be a filesystem on its own device. The mount point used here is `/var/lib/librefs/object-storage`. The systemd unit waits for that path to be mounted before it starts the stack.

On the storage host, list disks and pick the new empty one. Size, model, and an empty `FSTYPE` column are the check. The OS disk already has a mount on `/`.

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
```

The commands below use `/dev/sdb`. Substitute the name from `lsblk`. This erases that device.

```sh
sudo parted -s /dev/sdb mklabel gpt mkpart primary ext4 1MiB 100%
sudo mkfs.ext4 -L librefs-data /dev/sdb1
sudo mkdir -p /var/lib/librefs/object-storage
sudo mount /dev/sdb1 /var/lib/librefs/object-storage
```

`parted` writes one GPT partition that fills the disk. `mkfs.ext4` formats it. Add `discard` to the mount options below when the device is an SSD.

Persist the mount by UUID so a reboot does not depend on the `/dev/sdX` name:

```sh
UUID=$(sudo blkid -s UUID -o value /dev/sdb1)
echo "UUID=${UUID} /var/lib/librefs/object-storage ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
sudo umount /var/lib/librefs/object-storage
sudo mount -a
findmnt /var/lib/librefs/object-storage
```

Set `DATA_DIR=/var/lib/librefs/object-storage` in `.env`. If objects were already written under `./data`, stop the stack and copy them onto the new filesystem before starting again:

```sh
docker compose stop
sudo rsync -a ./data/ /var/lib/librefs/object-storage/
docker compose up -d
```

## Run it

On the Linux host:

```sh
git clone <this repo> /opt/librefs
cd /opt/librefs
sh scripts/init.sh
```

Edit `.env` and set `DATA_DIR` to a dedicated filesystem (for example `/var/lib/librefs/object-storage`) before the first start. Then:

```sh
docker compose up -d
docker compose ps
```

`docker ps` lists `master`, `volume`, and `filer` as healthy. `render-s3-config` exits after it writes the key file. `admin` is the UI on port 23646.

## Web UI

The `admin` container is SeaweedFS's own browser UI: cluster status, buckets, users, and a file browser with upload and delete. It uses the same image as the storage containers and talks to the master and filer on the internal network. It does not hold object bytes.

Open `http://<host>:23646`. The username is `WEED_ADMIN_USER` (default `admin`). The password is `WEED_ADMIN_PASSWORD` in `.env`.

An access key created in the UI for an S3 user does not log into this page. That key is for the S3 API on port 8333. The UI login is only the admin username and `WEED_ADMIN_PASSWORD`.

If this stack was created before the UI existed, add the password and start the new container:

```sh
sh scripts/init.sh
docker compose up -d
```

`init.sh` leaves existing S3 keys alone and appends a UI password when `.env` does not have one. Set `ADMIN_BIND` to the same address as `S3_BIND` (use `0.0.0.0` when you open the UI from another machine on the LAN). The UI refuses to listen on a public address without that password.

In the UI, buckets and users are under Object Store. The file browser shows bucket contents under `/buckets/<name>`.

## Buckets and users

Two binaries. `aws` creates buckets and moves objects. `weed`, already in the SeaweedFS image, creates users and limits them to a bucket. The Admin UI can create those users too; the shell is what you script.

The key in `.env` is the global admin. It can create buckets and read every bucket. A limited user cannot create a bucket, so create the bucket with the admin key first. Region is `us-east-1`. SeaweedFS does not use it for placement. Path-style addressing is required.

```sh
export AWS_ACCESS_KEY_ID=<S3_ACCESS_KEY from .env>
export AWS_SECRET_ACCESS_KEY=<S3_SECRET_KEY from .env>
export AWS_DEFAULT_REGION=us-east-1
aws configure set default.s3.addressing_style path
aws --endpoint-url http://127.0.0.1:8333 s3 mb s3://photos
echo hello | aws --endpoint-url http://127.0.0.1:8333 s3 cp - s3://photos/hello.txt
aws --endpoint-url http://127.0.0.1:8333 s3 ls s3://photos
```

Then provision a user. `weed` prints an access key and a secret once. Save them. Roles are `readonly` (get and list), `readwrite` (get, put, delete, list), and `admin` (settings for that bucket only, not the whole cluster).

```sh
docker compose exec filer weed shell -master=master:9333 -filer=localhost:8888
```

```text
s3.user.provision -name photos-app -bucket photos -role readwrite
s3.user.provision -name photos-app -bucket archive -role readonly
s3.user.show -name photos-app
```

The second `s3.user.provision` adds `archive` and keeps the existing key. Check the limit with that new key. `photos` works. Another bucket returns Access Denied.

```sh
AWS_ACCESS_KEY_ID=<new access key> AWS_SECRET_ACCESS_KEY=<new secret> AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url http://127.0.0.1:8333 s3 ls s3://photos
```

Users from `s3.user.provision` or the Admin UI are stored beside the static `librefs` identity in `s3.json`. They do not replace it.

In the Admin UI, edit the user under **Object Store → Users**. Set bucket scope to that bucket. **All buckets** gives the user every bucket. Grant `List` and `Read` to a client that only downloads. Add `Write` for a client that uploads. Leave global `Admin` off.

## Access levels, roles, and policies

Three levels are enough. Use the smallest one that does the job.

| Who | What they get | Where it lives |
| --- | --- | --- |
| You, operating the server | Global admin. Create buckets, recover access. | `S3_ACCESS_KEY` in `.env`, loaded from `s3.json`. Stays on the server. |
| One application | One user, one role, one or a few buckets. | Admin UI, or `s3.user.provision`. |
| A person you send a file to | A presigned URL that expires. No user, no password. | `aws s3 presign`. |

Do not put the `.env` admin key in an application. Do not make a bucket world-readable so that a link works. A presigned URL is the share mechanism.

### Roles

`s3.user.provision -role` creates a policy for that bucket and attaches it. These are the roles:

| Role | Allowed on that bucket | Use it for |
| --- | --- | --- |
| `readonly` | Get objects, list keys | A service that only downloads. |
| `readwrite` | Get, put, delete, list | The service that owns the bucket. |
| `admin` | Bucket settings for that bucket | Rare. Not for uploads, and not cluster admin. |

The same user can hold different roles on different buckets. A second `s3.user.provision` adds the bucket and keeps the existing access key:

```text
s3.user.provision -name photos-app -bucket photos -role readwrite
s3.user.provision -name photos-app -bucket archive -role readonly
```

A writer and a reader of the same bucket should be two users. Name the user after the application (`photos-app`, `photos-reader`), not after a person.

For a user you already created in the UI, set the same boundary there. **Object Store → Users → Edit**:

- Bucket scope: the one bucket. **All buckets** is global data access.
- Permissions: `List` and `Read`, plus `Write` only for an uploader.
- Leave global `Admin` unchecked.

### Actions

The user form uses short names. A policy uses the S3 action names. They mean the same thing. The bucket is named in the policy `Resource`, or by **Bucket scope** on the user form.

| UI name | Policy action | What it allows |
| --- | --- | --- |
| `List` | `s3:ListBucket` | See object keys. Resource is the bucket: `arn:aws:s3:::photos`. |
| `Read` | `s3:GetObject` | Download. Resource is the objects: `arn:aws:s3:::photos/*`. |
| `Write` | `s3:PutObject`, `s3:DeleteObject` | Upload and delete objects in `photos/*`. |
| `Tagging` | `s3:GetObjectTagging`, `s3:PutObjectTagging` | Read and set object tags. Skip this unless the app uses tags. |
| `Admin` | Every action, including bucket create and delete | Operator only. With **All buckets** this is the global admin. |

`List` without `Read` can see names and cannot download. `Read` without `List` can download a known key and cannot browse. A normal reader gets both. None of these create a bucket. Bucket creation stays with the `.env` admin key.

### Policies

A policy is the document that names actions and buckets. Create it under **Object Store → Policies**. One policy per job.

Reader, `photos-read`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::photos"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::photos/*"]
    }
  ]
}
```

Writer, `photos-write`. This includes download, because an uploader usually has to read back what it stored:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::photos"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::photos/*"]
    }
  ]
}
```

`arn:aws:s3:::photos` is the bucket. `arn:aws:s3:::photos/*` is every object in it. Change `photos` to the bucket name. Do not use `s3:*` or `Resource: "*"`.

### Groups

A group is not a role until a policy is attached. Members then receive that policy. A group with no policy grants nothing.

Effective access for a user is their own policies plus the policies of every **enabled** group they belong to. Disabling a group drops those rights and leaves the users in place.

Wire it in this order:

1. Create the bucket with the admin key, or under **Object Store → Buckets**.
2. Create `photos-read` and `photos-write` under **Object Store → Policies**.
3. Open the group under **Object Store → Groups**. Attach one policy. Add the users as members.
4. On each user, under **Object Store → Users**, add them to that group. Leave **Actions** empty and leave **All buckets** off, so the group policy is the only grant.

Use two groups when the same bucket has readers and writers: `photos-readers` with `photos-read`, and `photos-writers` with `photos-write`. A user who only downloads is in the first group. The application that uploads is in the second.

You can attach the same policy directly on a user (**Attached policies**) when that user is the only one who needs it. A group is for several users who must stay in lockstep. A user can belong to more than one group. Attached policies on one identity are capped at 10.

### Check and rotate

After every grant, list the allowed bucket and one other bucket with that user's profile. The other bucket must return `AccessDenied`.

```sh
aws --profile seaweed_FX s3 ls s3://photos
aws --profile seaweed_FX s3 ls s3://archive
```

To rotate a key, create a second access key on the same user, point the application at it, confirm `s3 ls`, then delete the old key. Each profile in `~/.aws/credentials` still has one `aws_access_key_id` and one `aws_secret_access_key`.

## AWS CLI on Ubuntu

Install AWS CLI v2. The `awscli` apt package is the older v1 client.

```sh
sudo apt update
sudo apt install -y unzip curl
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
aws --version
```

On 64-bit ARM, use `awscli-exe-linux-aarch64.zip` instead.

Put the SeaweedFS user's keys in `~/.aws/credentials`. Each profile may contain `aws_access_key_id` once and `aws_secret_access_key` once. A repeated key makes the CLI stop with `Unable to parse config file`.

```ini
[seaweed_FX]
aws_access_key_id = <access key from the SeaweedFS user>
aws_secret_access_key = <secret from that same user>
```

Put the endpoint in `~/.aws/config`, not in the credentials file. The host must be the address clients use (`127.0.0.1` on the server, or the LAN address when you run the CLI from another machine).

```ini
[profile seaweed_FX]
region = us-east-1
output = json
endpoint_url = http://192.168.10.245:8333
s3 =
    addressing_style = path
```

```sh
aws --profile seaweed_FX s3 ls
aws --profile seaweed_FX s3 cp ./report.pdf s3://photos/report.pdf
aws --profile seaweed_FX s3 ls s3://photos
```

Use the limited user's profile for object work. Create buckets with the admin key from `.env`. A limited user receives `AccessDenied` on `s3 mb`.

## Share a download link

The Admin UI download button works for the logged-in operator. It does not produce a link you can send to someone else.

A shareable link is a presigned URL. SeaweedFS signs it, and the link works until it expires without the recipient having a key. The profile's `endpoint_url` is the host written into the link, so use the address the recipient can open.

```sh
aws --profile seaweed_FX s3 presign s3://photos/report.pdf --expires-in 3600
```

`--expires-in` is seconds. Anyone who has the URL can download the object until then. The user who signs it needs `Read` on that object. The URL is `http` unless you terminate TLS in front of port 8333.

## Application settings

From another container, attach to the `librefs-storage` network and use the internal endpoint. From a process on the same host, use localhost.

| Setting | Value |
| --- | --- |
| Endpoint (same host) | `http://127.0.0.1:8333` |
| Endpoint (other containers) | `http://filer:8333` |
| Region | `us-east-1` |
| Bucket | create `librefs`, or any name you choose |
| Addressing | path-style |
| Access key | `S3_ACCESS_KEY` |
| Secret key | `S3_SECRET_KEY` |

Other Compose projects join the network like this:

```yaml
services:
  app:
    networks:
      - librefs-storage

networks:
  librefs-storage:
    external: true
```

## Start on boot

Install the unit after the repo lives at `/opt/librefs` (edit `WorkingDirectory` if the path differs):

```sh
sudo cp deploy/librefs-object-storage.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now librefs-object-storage.service
```

The unit runs `docker compose up -d` and `docker compose stop`. It does not delete data.

## Backup and restore

The separate device is the live copy. It is not a backup. A dead disk, a bad `mkfs`, or deleting the mount loses the only copy. Put a second copy on another disk or another machine.

Copy the filesystem, not the S3 API. Uploading objects back into this same store does not protect you from losing the device.

This disk is one ext4 partition, so it has no snapshot of its own. Stop the stack, then copy. `volume` and `filer` must come from that same stopped moment. The filer index names needles inside the volume files. A newer index with older volume files, or the reverse, makes objects unreadable.

| Path | Backup |
| --- | --- |
| `$DATA_DIR/volume` | Required. The object bytes. |
| `$DATA_DIR/filer` | Required, from the same stop as `volume`. The bucket index. |
| `$DATA_DIR/config` | Required. `s3.json`, the global admin key. |
| `.env` | Required. Store it with your secrets, not inside the data disk's public copy. |
| `$DATA_DIR/master` | Optional. SeaweedFS rebuilds this map from the volume server. |
| `$DATA_DIR/admin` | Optional. UI state, not objects. |

From `/opt/librefs`, with `DATA_DIR=/var/lib/librefs/object-storage`:

```sh
docker compose stop
sudo mkdir -p /backup/librefs
sudo rsync -a --delete /var/lib/librefs/object-storage/ /backup/librefs/data/
sudo cp -a .env /backup/librefs/env
docker compose up -d
```

`/backup/librefs` must be a different device than `/var/lib/librefs/object-storage`. Confirm that with `findmnt` before the first run. `--delete` makes the backup match the source, including deletions. Keep more than one dated copy if you need to undo a bad backup:

```sh
sudo rsync -a /var/lib/librefs/object-storage/ /backup/librefs/$(date +%F)/
```

### Restore

Restore `volume`, `filer`, and `config` from the same backup. Confirm the data device is actually mounted before you copy anything. If the mount failed, `/var/lib/librefs/object-storage` is an empty directory on the OS disk and a restore would land in the wrong place.

```sh
findmnt /var/lib/librefs/object-storage
docker compose stop
sudo rsync -a --delete /backup/librefs/data/ /var/lib/librefs/object-storage/
sudo cp -a /backup/librefs/env /opt/librefs/.env
docker compose up -d
aws --profile seaweed_FX s3 ls
aws --profile seaweed_FX s3 cp s3://photos/report.pdf /tmp/report.pdf
```

`docker compose up` fixes ownership of each data directory for the SeaweedFS user inside the image. Download one object you know was in that backup. A bucket list alone does not prove the volume files came along with the index.

On a new server: mount the device at the same path (or set `DATA_DIR` to wherever it is mounted), restore `.env` next to the compose file, then `docker compose up -d`. The systemd unit waits for `/var/lib/librefs/object-storage` to be mounted before it starts the containers.

The filer store is local leveldb, which is what SeaweedFS recommends for a single filer. A second filer needs a shared metadata database such as Postgres. Move to that before you add another filer.

## Credentials

`scripts/init.sh` generates alphanumeric keys. Changing them means updating `.env`, then:

```sh
docker compose up -d --force-recreate render-s3-config filer
```

The long-running filer process reads `s3.json`. It does not read the key from its own environment.

## Growing past one machine

Add volume servers on other hosts first, each with its own disk, `-dataCenter`, and `-rack`. Point them at `master:9333`. When a second physical machine is actually in the cluster, switch `-defaultReplication` from `000` to `010` (one extra copy on another rack) and restart the master. Do that only after the extra volume server is healthy.

Three masters are optional. SeaweedFS treats the master as soft state; one master is a normal production setup. Three masters are for master failover, and they do not by themselves copy object data.

When you outgrow a single Compose host, put `weed` under systemd on each machine (or move to Ceph). Keep the same S3 endpoint in the application.

## Operations

```sh
docker compose logs -f filer volume master
docker compose exec master curl -fsS http://127.0.0.1:9333/cluster/healthz
```

The master UI is not published on the host. Use `docker compose exec` or a temporary SSH tunnel if you need it. Metrics listen inside the network on master `9324`, volume `9325`, and filer `9326`.

Image upgrades are intentional. Bump the tag and digest in `docker-compose.yml`, then `docker compose up -d`. Read the SeaweedFS release notes before jumping more than a few versions; volume files are not something to roll back casually.
