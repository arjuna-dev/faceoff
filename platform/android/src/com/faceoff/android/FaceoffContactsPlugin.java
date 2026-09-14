package com.faceoff.android;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import android.widget.Toast;
import android.telephony.PhoneNumberUtils;
import android.telephony.TelephonyManager;
import java.util.Locale;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.ContactsContract;
import android.provider.Telephony;

import org.json.JSONArray;
import org.json.JSONObject;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Small, privacy-preserving bridge used by the Contacts screen.
 *
 * Faceoff requests READ_CONTACTS from the Invite Friends flow. Once granted it returns
 * display names, phone numbers, and optional photo content URIs to Godot. The
 * Godot UI decides what to show and does not upload this data from this class.
 */
public final class FaceoffContactsPlugin extends GodotPlugin {
    private static final int READ_CONTACTS_REQUEST = 4107;
    private static final int MEDIA_PERMISSION_REQUEST = 4108;

    public FaceoffContactsPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "FaceoffContacts";
    }

    @Override
    public List<String> getPluginMethods() {
        return Arrays.asList("hasContactsPermission", "requestContactsPermission", "readContactsJson", "requestMediaPermission", "shareInvite", "shareInviteWithChannel", "shareInviteToPhone", "getInitialInviteUrl");
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        return new HashSet<>(Arrays.asList(
                new SignalInfo("contacts_permission_result", Boolean.TYPE),
                new SignalInfo("invite_url_received", String.class)));
    }

    private String lastInviteUrl = "";

    @UsedByGodot
    public String getInitialInviteUrl() {
        String url = currentInviteUrl();
        if (!url.isEmpty()) lastInviteUrl = url;
        return url;
    }

    @Override
    public void onMainResume() {
        super.onMainResume();
        String url = currentInviteUrl();
        if (url.isEmpty() || url.equals(lastInviteUrl)) return;
        lastInviteUrl = url;
        emitSignal("invite_url_received", url);
    }

    private String currentInviteUrl() {
        Activity activity = getActivity();
        if (activity == null) return "";
        Intent intent = activity.getIntent();
        Uri data = intent == null ? null : intent.getData();
        if (data == null || !"faceoff".equalsIgnoreCase(data.getScheme())
                || !"invite".equalsIgnoreCase(data.getHost())) return "";
        return data.toString();
    }

    @UsedByGodot
    public boolean hasContactsPermission() {
        Activity activity = getActivity();
        return activity != null && (Build.VERSION.SDK_INT < Build.VERSION_CODES.M
                || activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED);
    }

    @UsedByGodot
    public boolean requestContactsPermission() {
        Activity activity = getActivity();
        if (activity == null) {
            emitSignal("contacts_permission_result", false);
            return false;
        }
        if (hasContactsPermission()) {
            emitSignal("contacts_permission_result", true);
            return true;
        }
        activity.runOnUiThread(() -> getGodot().requestPermission(Manifest.permission.READ_CONTACTS));
        return false;
    }

    @UsedByGodot
    public String readContactsJson() {
        if (!hasContactsPermission()) {
            return errorJson("permission_required");
        }
        Activity activity = getActivity();
        if (activity == null) {
            return errorJson("contacts_unavailable");
        }
        JSONArray contacts = new JSONArray();
        Cursor cursor = null;
        try {
            ContentResolver resolver = activity.getContentResolver();
            Uri uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI;
            String[] projection = new String[]{
                    ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_URI
            };
            cursor = resolver.query(uri, projection, null, null,
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY + " COLLATE NOCASE ASC");
            if (cursor == null) {
                return contacts.toString();
            }
            int idIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.CONTACT_ID);
            int nameIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY);
            int phoneIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER);
            int photoIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.PHOTO_URI);
            HashSet<String> seen = new HashSet<>();
            TelephonyManager manager = (TelephonyManager) activity.getSystemService(Activity.TELEPHONY_SERVICE);
            String country = manager == null ? "" : manager.getSimCountryIso();
            if (country == null || country.isEmpty()) country = Locale.getDefault().getCountry();
            while (cursor.moveToNext()) {
                String id = idIndex >= 0 ? cursor.getString(idIndex) : "";
                String name = nameIndex >= 0 ? cursor.getString(nameIndex) : "";
                String phone = phoneIndex >= 0 ? cursor.getString(phoneIndex) : "";
                if (name == null || name.trim().isEmpty() || phone == null || phone.trim().isEmpty()) {
                    continue;
                }
                String normalized = PhoneNumberUtils.formatNumberToE164(phone, country.toUpperCase(Locale.ROOT));
                String storedPhone = normalized == null ? phone.trim() : normalized;
                String key = storedPhone.replaceAll("[^+0-9]", "");
                if (!seen.add(key)) {
                    continue;
                }
                JSONObject item = new JSONObject();
                item.put("id", id == null ? "" : id);
                item.put("name", name.trim());
                item.put("phone", storedPhone);
                if (photoIndex >= 0 && !cursor.isNull(photoIndex)) {
                    item.put("avatar_uri", cursor.getString(photoIndex));
                } else {
                    item.put("avatar_uri", "");
                }
                contacts.put(item);
            }
            return contacts.toString();
        } catch (Exception exception) {
            return errorJson("contacts_unavailable");
        } finally {
            if (cursor != null) {
                cursor.close();
            }
        }
    }

    @UsedByGodot
    public boolean requestMediaPermission(String permission) {
        Activity activity = getActivity();
        if (activity == null || permission == null || permission.trim().isEmpty()) {
            return false;
        }
        String requested = permission.trim();
        if (!Manifest.permission.RECORD_AUDIO.equals(requested)) return false;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M
                || activity.checkSelfPermission(requested) == PackageManager.PERMISSION_GRANTED) {
            return true;
        }
        activity.runOnUiThread(() -> getGodot().requestPermission(requested));
        return false;
    }

    @Override
    public void onMainRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults);
        for (int i = 0; i < permissions.length; i++) {
            if (Manifest.permission.READ_CONTACTS.equals(permissions[i])) {
                emitSignal("contacts_permission_result", i < grantResults.length && grantResults[i] == PackageManager.PERMISSION_GRANTED);
            }
        }
    }

    @UsedByGodot
    public void shareInvite(String text) {
        shareInviteWithChannel(text, "more");
    }

    @UsedByGodot
    public void shareInviteWithChannel(String text, String channel) {
        Activity activity = getActivity();
        if (activity == null) return;
        String selectedChannel = channel == null ? "more" : channel.trim().toLowerCase(Locale.ROOT);
        new Thread(() -> {
            try {
                File folder = new File(activity.getCacheDir(), "invites");
                if (!folder.exists() && !folder.mkdirs()) throw new IllegalStateException("Invite directory unavailable");
                File apk = new File(folder, "Faceoff.apk");
                try (FileInputStream input = new FileInputStream(activity.getApplicationInfo().sourceDir);
                     FileOutputStream output = new FileOutputStream(apk)) {
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                }
                Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".invites", apk);
                activity.runOnUiThread(() -> {
                    Intent intent = new Intent(Intent.ACTION_SEND);
                    intent.setType("application/vnd.android.package-archive");
                    intent.putExtra(Intent.EXTRA_TEXT, text);
                    intent.putExtra(Intent.EXTRA_STREAM, uri);
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    String unavailableMessage = "The selected app is not installed";
                    if ("sms".equals(selectedChannel)) {
                        String smsPackage = Telephony.Sms.getDefaultSmsPackage(activity);
                        if (smsPackage == null || smsPackage.isEmpty()) {
                            Toast.makeText(activity, "No SMS app is available", Toast.LENGTH_LONG).show();
                            return;
                        }
                        intent.setPackage(smsPackage);
                        intent.putExtra("sms_body", text);
                        unavailableMessage = "No SMS app is available";
                    } else if ("whatsapp".equals(selectedChannel)) {
                        intent.setPackage("com.whatsapp");
                        unavailableMessage = "WhatsApp is not installed";
                    } else if ("telegram".equals(selectedChannel)) {
                        intent.setPackage("org.telegram.messenger");
                        unavailableMessage = "Telegram is not installed";
                    }
                    try {
                        if ("more".equals(selectedChannel)) {
                            activity.startActivity(Intent.createChooser(intent, "Invite to Faceoff"));
                        } else {
                            activity.startActivity(intent);
                        }
                    } catch (ActivityNotFoundException exception) {
                        Toast.makeText(activity, unavailableMessage, Toast.LENGTH_LONG).show();
                    }
                });
            } catch (Exception exception) {
                activity.runOnUiThread(() -> Toast.makeText(activity, "Could not share the APK. Please share it from your downloads.", Toast.LENGTH_LONG).show());
            }
        }, "FaceoffApkShare").start();
    }

    @UsedByGodot
    public void shareInviteToPhone(String text, String phone) {
        Activity activity = getActivity();
        if (activity == null || phone == null || phone.trim().isEmpty()) return;
        activity.runOnUiThread(() -> {
            Intent intent = new Intent(Intent.ACTION_SENDTO);
            intent.setData(Uri.parse("smsto:" + Uri.encode(phone.trim())));
            intent.putExtra("sms_body", text == null ? "" : text);
            try {
                activity.startActivity(intent);
            } catch (ActivityNotFoundException exception) {
                Toast.makeText(activity, "No SMS app is available", Toast.LENGTH_LONG).show();
            }
        });
    }

    private String errorJson(String error) {
        try {
            JSONObject object = new JSONObject();
            object.put("error", error);
            return object.toString();
        } catch (Exception ignored) {
            return "{\"error\":\"contacts_unavailable\"}";
        }
    }
}
