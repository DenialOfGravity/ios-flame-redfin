/*
 * Application processor control interface - context initialization
 *
 * Copyright (C) 2023 The Sensor Shell Contributors
 *
 * This file is part of sensh.
 *
 * Sensh is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#ifndef LOCALCTL_H
#define LOCALCTL_H

#include "listener.h"

/*
 * Obtain a localctl interface instance. The interfaces array must be fully
 * initialized once the interface instance is used (when run_fastrpc_listener()
 * is called).
 */
struct fastrpc_interface *fastrpc_localctl_init(size_t n_ifaces,
						struct fastrpc_interface **ifaces);

void fastrpc_localctl_deinit(struct fastrpc_interface *iface);

#endif
