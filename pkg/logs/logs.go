// apparmor.d - Full set of apparmor profiles
// Copyright (C) 2021-2024 Alexandre Pujol <alexandre@pujol.io>
// SPDX-License-Identifier: GPL-2.0-only

package logs

import (
	"io"
	"regexp"
	"slices"
	"strings"

	"github.com/roddhjav/apparmor.d/pkg/aa"
	"github.com/roddhjav/apparmor.d/pkg/util"
)

// Colors
const (
	reset      = "\033[0m"
	fgGreen    = "\033[32m"
	fgYellow   = "\033[33m"
	fgBlue     = "\033[34m"
	fgMagenta  = "\033[35m"
	fgCian     = "\033[36m"
	fgWhite    = "\033[37m"
	boldRed    = "\033[1;31m"
	boldGreen  = "\033[1;32m"
	boldYellow = "\033[1;33m"
)

var (
	quoted                bool
	isAppArmorLogTemplate = regexp.MustCompile(`apparmor=("DENIED"|"ALLOWED"|"AUDIT")`)
	hex                   = `[0-9a-fA-F]`
	regCleanLogs          = util.ToRegexRepl([]string{
		// Clean apparmor log file
		`.*apparmor="`, `apparmor="`,
		`(peer_|)pid=[0-9]*\s`, " ",
		`\x1d`, " ",

		// Resolve classic user variables
		`/home/[^/]+/.cache`, `@{user_cache_dirs}`,
		`/home/[^/]+/.config`, `@{user_config_dirs}`,
		`/home/[^/]+/.local/share`, `@{user_share_dirs}`,
		`/home/[^/]+/.local/state`, `@{user_state_dirs}`,
		`/home/[^/]+/.local/bin`, `@{user_bin_dirs}`,
		`/home/[^/]+/.local/lib`, `@{user_lib_dirs}`,
		`/home/[^/]+/.ssh`, `@{HOME}/@{XDG_SSH_DIR}`,
		`/home/[^/]+/.gnupg`, `@{HOME}/@{XDG_GPG_DIR}`,
		`/home/[^/]+`, `@{HOME}`,

		// Resolve classic system variables
		`/usr/lib(|32|64|exec)`, `@{lib}`,
		`/usr/(|s)bin`, `@{bin}`,
		`x86_64-pc-linux-gnu[^/]?`, `@{multiarch}`,
		`/usr/etc/`, `@{etc_ro}/`,
		`/run/`, `@{run}/`,
		`user/[0-9]*/`, `user/@{uid}/`,
		`/proc/`, `@{PROC}/`,
		`@{PROC}/[0-9]*/`, `@{PROC}/@{pid}/`,
		`@{PROC}/@{pid}/task/[0-9]*/`, `@{PROC}/@{pid}/task/@{tid}/`,
		`/sys/`, `@{sys}/`,
		`@{PROC}@{sys}/`, `@{PROC}/sys/`,
		`pci` + strings.Repeat(hex, 4) + `:` + strings.Repeat(hex, 2), `@{pci_bus}`,

		// Some system glob
		`:1.[0-9]*`, `:*`, // dbus peer name
		`@{bin}/(|ba|da)sh`, `@{sh_path}`, // collect all shell
		`@{lib}/modules/[^/]+\/`, `@{lib}/modules/*/`, // strip kernel version numbers from kernel module accesses
		strings.Repeat(hex, 64), `@{hex64}`,
		strings.Repeat(hex, 32), `@{hex32}`,
		strings.Repeat(hex, 8) + `[-_]` + strings.Repeat(hex, 4) + `[-_]` + strings.Repeat(hex, 4) + `[-_]` + strings.Repeat(hex, 4) + `[-_]` + strings.Repeat(hex, 12), `@{uuid}`,

		// Remove basic rules from abstractions/base
		`(?m)^.*/etc/[^/]+so.*$`, ``,
		`(?m)^.*@{lib}/[^/]+so.*$`, ``,
		`(?m)^.*@{lib}/locale/.*$`, ``,
		`(?m)^.*/usr/share/locale[^/]?/.*$`, ``,
		`(?m)^.*/usr/share/zoneinfo[^/]?/.*$`, ``,
		`(?m)^.*/dev/(null|zero|full|log).*$`, ``,
		`(?m)^.*/dev/(u|)random.*$`, ``,
	})
)

type AppArmorLog map[string]string

// AppArmorLogs describes all apparmor log entries
type AppArmorLogs []AppArmorLog

func splitQuoted(r rune) bool {
	if r == '"' {
		quoted = !quoted
	}
	return !quoted && r == ' '
}

func toQuote(str string) string {
	if strings.Contains(str, " ") {
		return `"` + str + `"`
	}
	return str
}

// NewApparmorLogs return a new ApparmorLogs list of map from a log file
func NewApparmorLogs(file io.Reader, profile string) AppArmorLogs {
	logs := GetApparmorLogs(file, profile)

	// Parse log into ApparmorLog struct
	aaLogs := make(AppArmorLogs, 0)
	for _, log := range logs {
		quoted = false
		tmp := strings.FieldsFunc(log, splitQuoted)

		aa := make(AppArmorLog)
		for _, item := range tmp {
			kv := strings.Split(item, "=")
			if len(kv) >= 2 {
				aa[kv[0]] = strings.Trim(kv[1], `"`)
			}
		}
		aaLogs = append(aaLogs, aa)
	}

	return aaLogs
}

// String returns a formatted AppArmor logs string
func (aaLogs AppArmorLogs) String() string {
	// Apparmor log states
	state := map[string]string{
		"DENIED":  boldRed + "DENIED " + reset,
		"ALLOWED": boldGreen + "ALLOWED" + reset,
		"AUDIT":   boldYellow + "AUDIT  " + reset,
	}
	// Print order of impression
	keys := []string{
		"profile", "label", // Profile name
		"operation", "name", "target",
		"mask", "bus", "path", "interface", "member", // dbus
		"info", "comm",
		"laddr", "lport", "faddr", "fport", "family", "sock_type", "protocol",
		"requested_mask", "denied_mask", "signal", "peer", "peer_label",
	}
	// Key to not print
	ignore := []string{
		"fsuid", "ouid", "FSUID", "OUID", "exe", "SAUID", "sauid", "terminal",
		"UID", "AUID", "hostname", "class",
	}
	// Color template to use
	template := map[string]string{
		"profile":        fgBlue,
		"label":          fgBlue,
		"operation":      fgYellow,
		"name":           fgMagenta,
		"target":         "-> " + fgMagenta,
		"mask":           boldRed,
		"bus":            fgCian + "bus=",
		"path":           "path=" + fgWhite,
		"requested_mask": "requested_mask=" + boldRed,
		"denied_mask":    "denied_mask=" + boldRed,
		"interface":      "interface=" + fgWhite,
		"member":         "member=" + fgGreen,
	}
	var res strings.Builder

	for _, log := range aaLogs {
		seen := map[string]bool{"apparmor": true}
		res.WriteString(state[log["apparmor"]])
		fsuid := log["fsuid"]
		ouid := log["ouid"]

		for _, key := range keys {
			if item, present := log[key]; present {
				if key == "name" && fsuid == ouid && !strings.Contains(log["operation"], "dbus") {
					res.WriteString(template[key] + " owner" + reset)
				}
				if temp, present := template[key]; present {
					res.WriteString(" " + temp + toQuote(item) + reset)
				} else {
					res.WriteString(" " + key + "=" + toQuote(item))
				}
				seen[key] = true
			}
		}

		for key, value := range log {
			if slices.Contains(ignore, key) {
				continue
			}
			if _, present := seen[key]; !present && value != "" {
				res.WriteString(" " + key + "=" + toQuote(value))
			}
		}
		res.WriteString("\n")
	}
	return res.String()
}

// ParseToProfiles convert the log data into a new AppArmorProfiles
func (aaLogs AppArmorLogs) ParseToProfiles() aa.AppArmorProfiles {
	profiles := make(aa.AppArmorProfiles, 0)
	for _, log := range aaLogs {
		name := ""
		if strings.Contains(log["operation"], "dbus") {
			name = log["label"]
		} else {
			name = log["profile"]
		}

		if _, ok := profiles[name]; !ok {
			profile := &aa.AppArmorProfile{}
			profile.Name = name
			profile.AddRule(log)
			profiles[name] = profile
		} else {
			profiles[name].AddRule(log)
		}
	}
	return profiles
}
