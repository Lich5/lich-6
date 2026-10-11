# Lich 5

[![Release](https://img.shields.io/github/v/release/elanthia-online/lich-5)](https://github.com/elanthia-online/lich-5/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/elanthia-online/lich-5/rspec_tests.yaml?branch=main&label=rspec)](https://github.com/elanthia-online/lich-5/actions)
[![CI](https://img.shields.io/github/actions/workflow/status/elanthia-online/lich-5/rubocop.yaml?branch=main&label=rubocop)](https://github.com/elanthia-online/lich-5/actions)

[![Lich-5-Docs](https://img.shields.io/badge/Lich--5--Docs-blue)](https://lich-5-docs.elanthia.online/)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/elanthia-online/lich-5)

## About

This lich-6 development repository builds on Lich 5 with a WebUI launcher and script interfaces. The current graphical runtime does not require native GTK. A bounded, script-local GTK compatibility shim helps existing scripts migrate to native WebUI; unsupported calls are explicitly refused. See the [architecture guide](docs/webui-integration.md) and [review readiness](docs/webui-review-readiness.md) for implementation boundaries and remaining acceptance work. These development changes are not a claim that an EO release includes them.

Lich is an open source scripting engine for Simutronics' text-based games DragonRealms and GemStone IV. It operates alongside a chosen frontend and allows users to write and run scripts in Ruby.

Lich was originally created by Shaelun, who brought it up from an idea to version 3.57. Starting with version 3.58, Lich was maintained by Tillmen until version 5. Starting with version 5 of Lich, a community effort started to maintain and expand upon Lich and is now home here under the Elanthia-Online team.

## Usage

The following links and badges refer to the upstream Lich 5 project and released installation guidance. Development WebUI host prerequisites and validation commands are documented in the architecture guide linked above.

* DragonRealms - https://github.com/elanthia-online/lich-5/wiki/Documentation-for-Installing-and-Upgrading-Lich
* Gemstone IV - https://gswiki.play.net/Lich:Software/Installation
