package energy.ftw.protocol

const val PROTO_MIN = 0
const val PROTO_MAX = 1

fun helloEnvelope(build: String, ua: String, locales: List<String>, bucket: Int = 512, hz: Int = 1): Cbor {
    return Cbor.map(
        "t" to Cbor.txt("hello"),
        "b" to Cbor.map(
            "proto" to Cbor.map("min" to Cbor.num(PROTO_MIN), "max" to Cbor.num(PROTO_MAX)),
            "app" to Cbor.map("build" to Cbor.txt(build), "ua" to Cbor.txt(ua)),
            "locales" to Cbor.Arr(locales.map { Cbor.txt(it) }),
            "sub" to Cbor.map("bucket" to Cbor.num(bucket), "hz" to Cbor.num(hz)),
        ),
    )
}

fun subEnvelope(bucket: Int = 512, hz: Int = 1): Cbor =
    Cbor.map("t" to Cbor.txt("sub"), "b" to Cbor.map("bucket" to Cbor.num(bucket), "hz" to Cbor.num(hz)))
