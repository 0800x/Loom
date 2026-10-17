package app.loom.messenger

/** Public service class only; never an account, address, key or stable peer ID. */
internal object NearbyDiscoveryProtocol {
    fun kind(rendezvous: String): Int = when {
        rendezvous.startsWith("msg-gw-v1-") -> 1
        rendezvous.startsWith("pg1-") -> 2
        rendezvous.startsWith("dtn-rp1-") -> 3
        rendezvous.startsWith("dtn-dx1-") -> 4
        else -> 0
    }

    fun rendezvous(kind: Int, token: String): String? = when (kind) {
        0 -> "dtn-v2-peer-$token"
        1 -> "msg-gw-v1-$token"
        2 -> "pg1-peer-$token"
        3 -> "dtn-rp1-$token"
        4 -> "dtn-dx1-$token"
        else -> null
    }

    // PSM uses 16 bits. Reuse the unused bits of the existing four-byte field
    // so the BLE advertisement still fits the legacy 31-byte advertising limit.
    fun packedPsm(psm: Int, rendezvous: String): Int {
        require(psm in 1..0xffff)
        return psm or (kind(rendezvous) shl 16)
    }
}
