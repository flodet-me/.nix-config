# Yubikey

For authentication, encryption and signing of information [YubiKey](https://www.yubico.com/) are used.

## Initial setup

On a machine installed from this config this is automatic: `programs.gpg.publicKeys`
imports `keys/flodet.asc` with full trust, and a user service makes gpg learn the
YubiKey at login and whenever it is plugged in. Only for a machine outside this
config, import the public key and trust it by hand.

```bash
gpg --import keys/flodet.asc
```

Then get the key by executing the following command and extract the id under `General key info` after `0x`.

```bash
gpg --card status
```

Next edit the key

```bash
gpg --edit-key {YOUR_KEY_ID}
```

And the following commands:

```gpg
trust
5
y
save
```

## SSH setup

To use the GPG key for SSH you need to add the authentication key to the `sshcontrol`.

Find the Authentication [A] subkey's Keygrip:

```bash
gpg --list-keys --with-keygrip
```

Add the keygrip to SSH control file:

```bash
echo "{KEYGRIP}" >> ~/.gnupg/sshcontrol
```

Run the following command to verify the addition:

```bash
ssh-add -L
```

Now you can use the key for git or any other ssh based authentication.

## Resources

- https://github.com/drduh/YubiKey-Guide
- https://developer.okta.com/blog/2021/07/07/developers-guide-to-gpg#enable-your-gpg-key-for-ssh
- https://gist.github.com/mcattarinussi/834fc4b641ff4572018d0c665e5a94d3
