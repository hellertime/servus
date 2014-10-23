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

## Enabling HA

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

## Enabling Durability

Durable state can be had with `servus` by way of kafka.

Here is how to run `servus` with HA enabled, and using kafka:

```
~$ servus --quorum --durable
```

Note that durability is independent of quorum; however, for multiple
`servus` instances to use the same kafka services for durability, a
quorum is needed to ensure consistency.

# Servus Task Flow

The Servus process maintains a library of executable tasks. These tasks
can be passed to Servus from the configuration file, or using the REST API.

There are multiple methods to execute a task:

* A task can be configured with a schedule (CRON) and Servus will execute the
  task as demanded.
* A task can expose an HTTP endpoint through the Servus REST API, and a HTTP
  POST to this endpoint can trigger the task to execute.

Tasks can take parameters. These parameters can be included in the task configuration,
and can be overridden when triggering a task via the REST API.

When a Task is to be executed, a TaskInstance is created and scheduled.

**TODO** Can a framework request less resources for an executor, and if so, does a slave 
         honor the request? Or does it ignore it. (i.e. Can an executor relinquish
         resources allocated to it?)

A TaskInstance begins in the SLEEP state, and is put on the SLEEP-QUEUE. There it awaits
offers from mesos which match its constraints. When an offer match is made, Servus will
move the task to the LAUNCHED state, and launch the task on the executor. LAUNCHED tasks
are put on to the LAUNCHED-QUEUE and remain there until a status update which puts the 
task into a TERMINAL state. Tasks in the TERMINAL state are moved to the TERMINAL-QUEUE
and are processed off the queue and the final status is written to a history log.

**NOTE** Is there a case in which a TERMINAL task should be put back to SLEEP instead?
**NOTE** SLEEP-QUEUE is a misnomer. Since offers are not handed out in FIFO order, but
         instead a best-match algorithm will be used to pair SLEEP tasks to an offer.
         Ties should be broken by sleep time (longest wins), then by historical run 
         time (shortest wins)

## Task Flow Threads

### ClockThread

A ClockThread maintains a sorted set of all schedulable tasks, and continuously sorts
the set of schedules into increasing chronological order. The thread operates a 1Hz, 
the sort is time-bounded so that if it takes longer than 1Hz to complete it will pause
and the current lowest value is scheduled if ready. If the sort takes < 1Hz, the thread
will sleep until its next cycle. Entries with the same launch time are grouped, and 
sorted as a unit, and scheduled at once.

Tasks are associated with a Slack value and a MaxConcurrent value.

If the ClockThread misses a schdule moment, but on its next cycle the Task 
moment + slack > currentTime than the task will still be considered for scheduling.i
Otherwise it will be put on the TERMINAL queue.

The value of MaxConcurrent is used to cap the number of TaskInstances which can be in the
SLEEP or LAUNCHED states at a given time. If SLEEP + LAUNCHED < MaxConcurrent the ClockThread
will continue to create new TaskInstances in the SLEEP state. Otherwise the task will start in
the TERMINAL state.

### OfferThread

The OfferThread is an instance of a MesosScheduler. When passed offers from mesos, the thread
will compute a set of launch-able tasks from the set of offers and the set of SLEEP tasks.

This has to be fast so a first-fit algorithm is used. 

**NOTE** Might some form of next-fit be more appropriate? What about the approach used by sparrow?

The OfferThread must also respond to status updates and properly transition tasks from LAUNCHED to
TERMINAL.

### TerminalThread

The TerminalThread will process TERMINAL tasks, and log them to history.

### TriggerThread (Pool?)

When a task is added to the library, it can choose to register a trigger URI which is exposed in the
REST API. The trigger URIs are handled by the TriggerThread, seperate from the other parts of the 
REST API.

This thread responds to HTTP POST messages by creating a TaskInstance in the SLEEP state and returning
a control URL which can be used to monitor and manage the TaskInstance.

**NOTE** The control URL is not unique to the TriggerThread, any TaskInstance will have an associated
         control URL which can be used to manage the Task remotely.
**NOTE** Review this design when surveying HTTP server libraries to back the REST API.
