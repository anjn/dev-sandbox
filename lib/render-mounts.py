#!/usr/bin/env python3

import json
import sys


def main(arguments: list[str]) -> None:
    if len(arguments) % 3 != 0:
        raise SystemExit("mount arguments must be source/target/mode triples")

    volumes = []
    for index in range(0, len(arguments), 3):
        source, target, mode = arguments[index : index + 3]
        volumes.append(
            {
                "type": "bind",
                "source": source,
                "target": target,
                "read_only": mode == "ro",
            }
        )

    json.dump({"services": {"dev": {"volumes": volumes}}}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
