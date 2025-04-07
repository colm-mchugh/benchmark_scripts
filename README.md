
# Setup
Setup for running bcc and flamegraph in a docker container

## Install packages:

``` 
tdnf install python3-bcc kernel-devel kernel-headers bcc-tools bpftrace
tdnf install kernel-devel-$(uname -r)
tdnf install kernel-headers-$(uname -r)
```

## Mount debugfs:
```
mount -t debugfs debugfs /sys/kernel/debug
```

## Get Flamegraph and bcc source

```
git clone https://github.com/brendangregg/FlameGraph.git
git clone https://github.com/iovisor/bcc.git
```

## Change bcc source:

```
diff --git a/tools/offcputime.py b/tools/offcputime.py
index efb449c4..b1c841a1 100755
--- a/tools/offcputime.py
+++ b/tools/offcputime.py
@@ -1,4 +1,4 @@
-#!/usr/bin/env python
+#!/usr/bin/env python3
#
# offcputime    Summarize off-CPU time by stack trace
#               For Linux, uses BCC, eBPF.
diff --git a/tools/offwaketime.py b/tools/offwaketime.py
index 0b135fb4..f408ada7 100755
--- a/tools/offwaketime.py
+++ b/tools/offwaketime.py
@@ -1,4 +1,4 @@
-#!/usr/bin/env python
+#!/usr/bin/env python3
#
# offwaketime   Summarize blocked time by kernel off-CPU stack + waker stack
#               For Linux, uses BCC, eBPF.
diff --git a/tools/wakeuptime.py b/tools/wakeuptime.py
index 8c5d628e..c8b37b5f 100755
--- a/tools/wakeuptime.py
+++ b/tools/wakeuptime.py
@@ -1,4 +1,4 @@
-#!/usr/bin/env python
+#!/usr/bin/env python3
#
# wakeuptime    Summarize sleep to wakeup time by waker kernel stack
#               For Linux, uses BCC, eBPF.
@@ -242,7 +242,7 @@ while (1):
     stack_traces = b.get_table("stack_traces")
     for k, v in sorted(counts.items_lookup_and_delete_batch()
                         if htab_batch_ops else counts.items(),
-                        key=lambda counts: counts[1].value):
+                        key=lambda counts: (counts[1] if type(counts[1]) is int else counts[1].value)):
         # handle get_stackid errors
         # check for an ENOMEM error
         if k.w_k_stack_id == -errno.ENOMEM:
@@ -259,14 +259,14 @@ while (1):
                 [b.ksym(addr)
                     for addr in reversed(waker_kernel_stack)] + \
                 [k.target]
-            printb(b"%s %d" % (b";".join(line), v.value))
+            printb(b"%s %d" % (b";".join(line), (v if type(v) is int else v.value)))
         else:
             # print default multi-line stack output
             printb(b"    %-16s %s" % (b"target:", k.target))
             for addr in waker_kernel_stack:
                 printb(b"    %-16x %s" % (addr, b.ksym(addr, False, True)))
             printb(b"    %-16s %s" % (b"waker:", k.waker))
-            print("        %d\n" % v.value)
+            print("        %d\n" % (v if type(v) is int else v.value))
 
     if not htab_batch_ops:
         counts.clear()
```
