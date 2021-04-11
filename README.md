# Infrastructure for vectornet

There are still some references to my own user and ssh key. These will
be fixed as the project progresses.

## To do

1. Clean up workers configuration

   Currently worker setup requires adding a worker in
   `./lib/synapse-workers.nix`, then adding it to nginx in
   `./modules/matrix-synapse.nix`.  This should be streamlined by
   defining workers in network or host configuration json, and
   generating all of the config based on those.

2. Port to morph (https://github.com/DBCDK/morph) instead of nixops.

   Morph looks like a nice stateless alternative to nixops.  The state
   of nixops makes it hard for other users to deploy/manage the same
   network as the state includes things like absolute paths on the
   host that runs the deployment.

3. Make this a set of modules that are embedded in a separate
   configuration repository, rather than a monolithic server build
   tool.  That makes it easier to port to other configurations and
   reuse elsewhere.  Currently this is very tightly bound to a
   specific deployment.

4. A lot of the nix code can probably be cleaned up generally; this
   project has grown quite organically over time.

### Create a new server and install a base NixOS

1. Set up hcloud https://github.com/hetznercloud/cli

2. Add your SSH key to the hcloud project

3. Enter the nix shell

```
$ nix-shell -A create
```

4. Create a server

```
# Args are FQDN, type, location, volume size, ssh key name
$ ./bin/hcloud-create-server.sh vecnetapp1.vectornet.fi cpx21 hel1 20 sjagoe@simon-x1
... lots of output
```

5. Commit the new files and changes

### Deploy to the new machine

1. Enter the nix shell

```
$ nix-shell -A nixops
```

2. Update `machines.nix` with the definition of the new server.

3. First time setup

```
$ nixops create -d matrix-synapse ./machines.nix
```

4. Update the deployments

```
$ nixops deploy -d matrix-synapse
```

## nix install script

`./lib/install-nix.sh` is from
<https://releases.nixos.org/?prefix=nix/>, stored locally to not
require downloading on every host install.

## nixos installer script

The nixos installer script (./lib/cloud-instal-rescue.sh) is based on
both the hetzner-cloud and hetzner robot community install scripts,
and heavily modified:

- https://github.com/nix-community/nixos-install-scripts/tree/master/hosters/hetzner-cloud
- https://github.com/nix-community/nixos-install-scripts/tree/master/hosters/hetzner-dedicated
