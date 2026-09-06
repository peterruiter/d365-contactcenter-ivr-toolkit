#!/usr/bin/env python3
"""Generate the custom connector swagger from build/customapis.json.

The connector surface is generated, never hand written. Tool names, descriptions and
input schemas drive orchestration in a generative agent, so a drift between what the
API accepts and what the connector advertises shows up as the agent calling the wrong
thing. That is much harder to diagnose than a 400.

Run after any change to customapis.json:
    python3 build/Build-Swagger.py
"""
import json
import collections
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "build" / "customapis.json"
OUTPUT = ROOT / "connector" / "apiDefinition.swagger.json"

TYPES = {"Boolean": "boolean", "Integer": "integer", "Decimal": "number", "Float": "number"}
FORMATS = {"DateTime": "date-time"}


def swagger_type(dataverse_type):
    return TYPES.get(dataverse_type, "string")


def build_property(item):
    prop = {"type": swagger_type(item["type"]), "x-ms-summary": item["name"]}
    if item.get("description"):
        prop["description"] = item["description"]
    if item["type"] in FORMATS:
        prop["format"] = FORMATS[item["type"]]
    return prop


def main():
    contract = json.loads(CONTRACT.read_text())
    paths = collections.OrderedDict()
    definitions = collections.OrderedDict()

    for api in contract["apis"]:
        # Internal APIs are for flows, not agents. They never reach the connector.
        # Note this is not the platform's isprivate flag, see Register-CustomApis.ps1.
        if api.get("internal"):
            continue

        name = api["name"]
        short = name.replace("pwrp_", "")

        properties = collections.OrderedDict(
            (o["name"], build_property(o))
            for o in list(api["outputs"]) + list(contract["sharedOutputs"])
        )
        definitions[short + "Response"] = {"type": "object", "properties": properties}
        response = {"200": {"description": api["displayName"],
                            "schema": {"$ref": "#/definitions/%sResponse" % short}}}

        if api["isFunction"]:
            inline = ",".join(
                "%s=@{encodeURIComponent(parameters('%s'))}" % (i["name"], i["name"])
                for i in api["inputs"]
            )
            path = "/%s(%s)" % (name, inline)
            parameters = []
            for i in api["inputs"]:
                param = {"name": i["name"], "in": "path", "required": True,
                         "type": swagger_type(i["type"]), "x-ms-summary": i["name"]}
                if i.get("description"):
                    param["description"] = i["description"]
                parameters.append(param)

            paths[path] = {"get": {
                "summary": api["displayName"],
                "description": api["description"],
                "operationId": short,
                "parameters": parameters,
                "responses": response,
            }}
        else:
            request_properties = collections.OrderedDict(
                (i["name"], build_property(i)) for i in api["inputs"]
            )
            request = {"type": "object", "properties": request_properties}
            required = [i["name"] for i in api["inputs"] if i.get("required")]
            if required:
                request["required"] = required
            definitions[short + "Request"] = request

            paths["/" + name] = {"post": {
                "summary": api["displayName"],
                "description": api["description"],
                "operationId": short,
                "parameters": [{"name": "body", "in": "body", "required": True,
                                "schema": {"$ref": "#/definitions/%sRequest" % short}}],
                "responses": response,
            }}

    swagger = collections.OrderedDict([
        ("swagger", "2.0"),
        ("info", {
            "title": "Contact Center IVR Toolkit",
            "description": (
                "Queue state, opening hours, live wait times and callbacks for Dynamics 365 "
                "Contact Center, shaped for voice agents. Every operation accepts a queue name "
                "or id and returns a speakable string alongside structured data. Start with "
                "GetQueueContext: it answers open or closed, how busy, is there an outage and "
                "what to do next, in one call."
            ),
            "version": "1.0",
            "contact": {"name": "Power Pete"},
        }),
        ("host", "{organisation}.api.crm4.dynamics.com"),
        ("basePath", "/api/data/v9.2"),
        ("schemes", ["https"]),
        ("consumes", ["application/json"]),
        ("produces", ["application/json"]),
        ("paths", paths),
        ("definitions", definitions),
        ("securityDefinitions", {"oauth2_auth": {
            "type": "oauth2",
            "flow": "accessCode",
            "authorizationUrl": "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "tokenUrl": "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "scopes": {},
        }}),
        ("security", [{"oauth2_auth": []}]),
    ])

    # newline="\n" is not decoration. write_text opens in text mode, which rewrites every
    # newline as CRLF on Windows and leaves it as LF everywhere else, so the same contract
    # produced two different files depending on who ran the generator. The build compares
    # this file against the committed one to catch a stale connector, and that comparison
    # is only meaningful if the output is byte for byte reproducible.
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(swagger, indent=2) + "\n")
    print("Wrote %s: %d operations, %d definitions" % (OUTPUT.name, len(paths), len(definitions)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
