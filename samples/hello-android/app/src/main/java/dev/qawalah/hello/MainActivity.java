package dev.qawalah.hello;

import android.app.Activity;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.TextView;

/** Minimal app used to verify the DevStore Android pipeline end to end. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView text = new TextView(this);
        text.setGravity(Gravity.CENTER);
        text.setTextSize(24);
        text.setText("DevStore Hello\nversion " + versionName());
        setContentView(text);
    }

    private String versionName() {
        try {
            PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            return info.versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "?";
        }
    }
}
