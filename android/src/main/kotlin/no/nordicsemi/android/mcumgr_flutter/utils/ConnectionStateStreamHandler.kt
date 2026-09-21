package no.nordicsemi.android.mcumgr_flutter.utils

import no.nordicsemi.android.mcumgr_flutter.ConnectionStateEvent
import no.nordicsemi.android.mcumgr_flutter.GetConnectionStateEventsStreamHandler
import no.nordicsemi.android.mcumgr_flutter.PigeonEventSink

class ConnectionStateStreamHandler : GetConnectionStateEventsStreamHandler() {
    private var sink: PigeonEventSink<ConnectionStateEvent>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<ConnectionStateEvent>) {
        this.sink = sink
    }

    override fun onCancel(p0: Any?) {
        this.sink = null
    }

    fun onEvent(event: ConnectionStateEvent) {
        sink?.success(event)
    }
}
