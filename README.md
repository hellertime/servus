servus: A Mesos framework, which does your bidding
==================================================

# Getting Started

Here is how to run `servus`:

```
~$ servus
```

By default `servus` will look for a mesos master specified
in the environment variable `MESOS\_MASTER` or, if that fails,
it will try `localhost:5050`.

A graphical interface can be visited at http://localhost:8080/.
The main interface displays the mesos tasks launched by `servus`.

A REST service endpoint is exposed at http://localhost:8081/.

# Enabling HA

Zookeeper is used as a primitive for high-availability. Mesos makes
use of zookeeper, so it is safe to assume zookeeper is available to
`servus` too.

Here is how to run `servus` with HA enabled:

```
~$ servus --quorum
```

By default `servus` will queue mesos tasks in memory on the quorum
leader. This is not a durable queue, and if the leader fails state is
lost.

# Enabling Durability

Durable state can be had with `servus` by way of kafka.

Here is how to run `servus` with HA enabled, and using kafka:

```
~$ servus --quorum --durable
```

Note that durability is independent of quorum; however, for multiple
`servus` instances to use the same kafka services for durability, a
quorum is needed to ensure consistency.
