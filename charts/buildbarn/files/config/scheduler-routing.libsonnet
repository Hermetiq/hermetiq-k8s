// Mounted only when scheduler.configurationReloadInterval is enabled.
// Routing and queue changes update this file without changing the pod checksum.
{
  {{ include "buildbarn.schedulerRouting" . }}
}
