// Mounted only when scheduler.configurationReloadInterval is enabled.
// Routing and queue changes update this file without changing the pod checksum.
// Preserve the shared configuration available to custom routers in scheduler.jsonnet.
// scheduler.jsonnet inherits this object so `$` still sees the complete scheduler.
local common = import 'common.libsonnet';

{
  {{ include "buildbarn.schedulerRouting" . }}
}
