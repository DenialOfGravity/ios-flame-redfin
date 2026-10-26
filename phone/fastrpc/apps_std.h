/*
 * fastrpcd: the DSP's apps_std file service over a directory tree (replaces hexagonrpcd's hexagonfs).
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd).
 */
#ifndef APPS_STD_H
#define APPS_STD_H

#include <stddef.h>
#include "listener.h"

/*
 * The DSP's paths are served from ROOT + the path, after these aliases:
 *   /system/vendor/...      -> /vendor/...
 *   /mnt/vendor/persist/... -> /persist/...
 * so the tree under ROOT is vendor/etc/sensors/{config,sns_reg_config}, vendor/etc/acdbdata,
 * persist/sensors/registry (the only writable part), sys/devices/soc0 (one file per attribute) and
 * usr/lib/qcom/adsp. ".." never leaves ROOT; neither does a symbolic link.
 */
struct fastrpc_interface *fastrpc_apps_std_init(const char *root);
void fastrpc_apps_std_deinit(struct fastrpc_interface *iface);

/* DSP path -> host path (exposed for the unit test). 0, or -1 if refused. */
int apps_std_map(const char *root, const char *dsp_path, int for_write, char *out, size_t n_out);

#endif
