local Util = require("blink_deps.util")
local Central = require("blink_deps.central")

local M = {}

M.GROUP_MIN_CHARS = 2
M.GROUP_ROWS = 200
M.ARTIFACT_ROWS = 200
M.VERSION_ROWS = 200

M.KIND = {
	Field = 5,
	Module = 9,
	Constant = 21,
}

M.BUILTIN_GROUP_HINTS = {
	"org.springframework",
	"org.springframework.boot",
	"org.springframework.data",
	"org.springframework.security",
	"org.springframework.kafka",
	"org.springframework.cloud",
	"org.springframework.batch",
	"org.springframework.ws",
	"org.apache.kafka",
	"org.apache.maven.plugins",
	"org.apache.logging.log4j",
	"org.apache.commons",
	"org.junit.jupiter",
	"org.junit.platform",
	"org.junit.vintage",
	"org.mockito",
	"org.hibernate.orm",
	"org.hibernate.validator",
	"org.postgresql",
	"org.mapstruct",
	"org.projectlombok",
	"org.flywaydb",
	"org.liquibase",
	"org.slf4j",
	"com.google.guava",
	"com.google.code.gson",
	"com.google.protobuf",
	"com.google.inject",
	"com.fasterxml.jackson.core",
	"com.fasterxml.jackson.databind",
	"com.fasterxml.jackson.datatype",
	"com.fasterxml.jackson.dataformat",
	"com.mysql",
	"io.micrometer",
	"io.projectreactor",
	"io.projectreactor.netty",
	"io.grpc",
	"io.netty",
	"ch.qos.logback",
}

function M.new_state()
	return {
		group_memory =
			Util.list_to_set(
				M.BUILTIN_GROUP_HINTS
			),
		central_cache = {},
		central_inflight = {},
		repository_cache = {},
		repository_inflight = {},
		artifact_catalog = {},
		version_catalog = {},
		notified = {},
	}
end

function M.notify_once(
	source,
	key,
	message,
	level
)
	if source.notified[key] then
		return
	end

	source.notified[key] = true

	vim.schedule(function()
		vim.notify(
			message,
			level or vim.log.levels.WARN
		)
	end)
end

function M.resolve(
	item,
	data_key,
	callback
)
	local resolved = vim.deepcopy(item)
	local data =
		resolved.data
		and resolved.data[data_key]

	if data
		and data.kind == "artifact"
	then
		resolved.documentation = {
			kind = "markdown",
			value = string.format(
				"**%s:%s**\n\nLatest: `%s`",
				data.groupId,
				data.artifactId,
				data.latestVersion
					or "unknown"
			),
		}
	elseif data
		and data.kind == "group"
	then
		resolved.documentation = {
			kind = "markdown",
			value =
				"**"
				.. data.groupId
				.. "**",
		}
	end

	callback(resolved)
end

function M.self_test()
	local known =
		Util.list_to_set(
			M.BUILTIN_GROUP_HINTS
		)

	return {
		spring_kafka =
			known[
				"org.springframework.kafka"
			] == true,
		apache_kafka =
			known[
				"org.apache.kafka"
			] == true,
		google_guava =
			known[
				"com.google.guava"
			] == true,
		central_url = Central.URL,
	}
end

return M
