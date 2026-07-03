# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- DRY/KISS refactor across the public framework surface before Hex publication.

### Breaking

- `composer.chat_type` now takes `types.ChatType` instead of `String`.

## [0.1.0] - 2026-07-03

### Added

- Initial release: API client (70+ typed methods plus generic `call`), composer middleware, filter DSL (typed plus grammY-style string queries), sessions, conversations, keyboards, inline query results, webhook adapter, transformers, and long-polling runner.
