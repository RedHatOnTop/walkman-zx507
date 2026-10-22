package dev.walkman.zx507.setup;

import android.view.View;

/** One step. Its views are made again on every render (a language change re-renders). */
abstract class Page {
    final SetupActivity mHost;

    Page(SetupActivity host) {
        mHost = host;
    }

    abstract CharSequence title();

    abstract CharSequence subtitle();

    /** A line under the subtitle, or null. */
    View header() {
        return null;
    }

    abstract View content();

    CharSequence nextLabel() {
        return mHost.getString(R.string.next);
    }

    void onNext() {}

    void onShown() {}

    void onHidden() {}
}
