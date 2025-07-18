// apparmor.d - Full set of apparmor profiles
// Copyright (C) 2021-2024 Alexandre Pujol <alexandre@pujol.io>
// SPDX-License-Identifier: GPL-2.0-only

package directive

import (
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/roddhjav/apparmor.d/pkg/prebuild"
	"github.com/roddhjav/apparmor.d/pkg/util"
)

var (
	regRules            = regexp.MustCompile(`(?m)^profile.*{$((.|\n)*)}`)
	regEndOfRules       = regexp.MustCompile(`(?m)([\t ]*include if exists <.*>\n)+}`)
	regCleanStakedRules = util.ToRegexRepl([]string{
		`(?m)^.*include <abstractions/base>.*$`, ``, // Remove mandatory base abstraction
		`(?m)^.*@{exec_path}.*$`, ``, // Remove entry point
		`(?m)^(?:[\t ]*(?:\r?\n))+`, ``, // Remove empty lines
	})
)

type Stack struct {
	prebuild.Base
}

func init() {
	RegisterDirective(&Stack{
		Base: prebuild.Base{
			Keyword: "stack",
			Msg:     "Stack directive applied",
			Help:    []string{"[X] profiles..."},
		},
	})
}

func (s Stack) Apply(opt *Option, profile string) (string, error) {
	if len(opt.ArgList) == 0 {
		return "", fmt.Errorf("no profile to stack")
	}
	t := opt.ArgList[0]
	if t != "X" {
		regCleanStakedRules = slices.Insert(regCleanStakedRules, 0,
			util.ToRegexRepl([]string{
				`(?m)^.*(|P|p)(|U|u)(|i)x,.*$`, ``, // Remove X transition rules
			})...,
		)
	} else {
		delete(opt.ArgMap, t)
	}

	res := ""
	for name := range opt.ArgMap {
		stackedProfile, err := prebuild.RootApparmord.Join(name).ReadFileAsString()
		if err != nil {
			return "", fmt.Errorf("%s need to stack: %w", name, err)
		}
		m := regRules.FindStringSubmatch(stackedProfile)
		if len(m) < 2 {
			return "", fmt.Errorf("no profile found in %s", name)
		}
		stackedRules := m[1]
		stackedRules = regCleanStakedRules.Replace(stackedRules)
		res += "  # Stacked profile: " + name + "\n" + stackedRules + "\n"
	}

	// Insert the stacked profile at the end of the current profile, remove the stack directive
	m := regEndOfRules.FindStringSubmatch(profile)
	if len(m) <= 1 {
		return "", fmt.Errorf("no end of rules found in %s", opt.File)
	}
	profile = strings.ReplaceAll(profile, m[0], res+m[0])
	profile = strings.ReplaceAll(profile, opt.Raw, "")
	return profile, nil
}
