# Testing the Vanilla Plus Megapack alpha

Thanks for testing. When something goes wrong, the pack's log is usually all we need to find out why. These four
steps make sure we get it.

## 1. Before you play: switch on Crash dump

In HellForge, open **Settings**, and under **Troubleshooting** tick **Crash dump**. It applies from the next session.

If the game crashes, HellForge then writes a full memory dump of the game into that session's logs. Know two things
about it:

- **It is big:** about 1 GB, sometimes more.
- **It is private:** it holds whatever the game had in memory, your Steam account name included. "Save logs to
  Desktop" scrubs the logs, but puts the dump into the zip as it is.

So after a crash, send the logs without the dump first: in HellForge, **Settings > Open session logs**, and move the
`crash-<number>.dmp` file out of that folder (to your Desktop, say) before you save the logs. Keep it until we say we
don't need it. We will ask for it only when the log is not enough, and then send it to us privately, never in a public
channel.

## 2. When something looks wrong: "Note a problem now"

Press Escape, open the **MODS** tab, go to the **VANILLA PLUS MEGAPACK** category, switch on **Note a problem now** and
apply. It switches itself back off and writes a numbered `MARK` line into the log, with what every component was doing
at that moment. Do it right away, while the problem is still on screen, and tell us the mark's number or roughly when
you pressed it.

## 3. Soon after: Save logs to Desktop

In HellForge, open **Console** and press **Save logs to Desktop**. It zips the last session's logs onto your Desktop.
Send us that zip.

Do it soon: HellForge keeps only the newest 10 sessions and deletes older ones, so a few more launches lose it.

## 4. Tell us your HellForge version

It is in HellForge's sidebar, under the session state: a line such as `HellForge 0.3.0`, with the game build below it. Copy both lines into your report, with a few words on what you did and what you saw.
