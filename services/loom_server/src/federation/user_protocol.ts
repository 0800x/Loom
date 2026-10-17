import { validateAvatar } from '../profile/profile.ts';
import { LoomNodeIdentity } from '../identity/node_identity.ts';
import { parseLoomAddress, normalizeLoomDomain } from './address.ts';
import type { RemoteUserProfile } from './routing_store.ts';
import { verifyDeviceKeyBundleRecord, type DeviceKeyBundleRecord } from '../security/device_bundle_store.ts';

export interface FederationUserProfile extends RemoteUserProfile {
  devices: DeviceKeyBundleRecord[];
}

export interface SignedFederationUserProfile extends FederationUserProfile {
  protocol: 'loom-federation-v1';
  signature: string;
}

function normalizedDevices(devices: DeviceKeyBundleRecord[]): DeviceKeyBundleRecord[] {
  return [...devices].sort((a, b) => a.deviceId.localeCompare(b.deviceId));
}

function payload(input: Omit<SignedFederationUserProfile, 'signature'>): string {
  return JSON.stringify({
    protocol: input.protocol,
    address: parseLoomAddress(input.address).canonical,
    displayName: input.displayName,
    ...(input.avatar === undefined ? {} : { avatar: validateAvatar(input.avatar) }),
    identity: input.identity,
    devices: normalizedDevices(input.devices),
    homeNode: {
      nodeId: input.homeNode.nodeId,
      domain: normalizeLoomDomain(input.homeNode.domain),
    },
    version: input.version,
    updatedAt: new Date(input.updatedAt).toISOString(),
  });
}

function validateDeviceList(
  devices: unknown,
  identityId: string,
  identityPublicKey: string,
): DeviceKeyBundleRecord[] {
  if (!Array.isArray(devices) || devices.length > 64) throw new Error('invalid_federation_user_devices');
  const seen = new Set<string>();
  return devices.map((value) => {
    const bundle = verifyDeviceKeyBundleRecord(value, identityId, identityPublicKey);
    if (!seen.add(bundle.deviceId)) throw new Error('invalid_federation_user_devices');
    return bundle;
  });
}

export function signFederationUserProfile(
  identity: LoomNodeIdentity,
  profile: RemoteUserProfile & { devices?: DeviceKeyBundleRecord[] },
): SignedFederationUserProfile {
  const unsigned: Omit<SignedFederationUserProfile, 'signature'> = {
    protocol: 'loom-federation-v1',
    ...profile,
    devices: normalizedDevices(profile.devices ?? []),
  };
  return { ...unsigned, signature: identity.signUtf8(payload(unsigned)) };
}

export function verifyFederationUserProfile(
  input: SignedFederationUserProfile,
  publicKey: string,
  expected: { address: string; nodeId: string; domain: string },
): FederationUserProfile {
  if (input.protocol !== 'loom-federation-v1') throw new Error('unsupported_federation_protocol');
  const address = parseLoomAddress(input.address).canonical;
  if (address !== parseLoomAddress(expected.address).canonical) throw new Error('federation_user_address_mismatch');
  if (input.homeNode.nodeId !== expected.nodeId || normalizeLoomDomain(input.homeNode.domain) !== normalizeLoomDomain(expected.domain)) throw new Error('federation_user_home_node_mismatch');
  if (!input.displayName || input.displayName.length > 80 || !input.identity?.identityId || !input.identity.publicKey || !input.identity.fingerprint) throw new Error('invalid_federation_user_profile');
  const devices = validateDeviceList(input.devices, input.identity.identityId, input.identity.publicKey);
  const unsigned = { ...input, devices } as SignedFederationUserProfile;
  delete (unsigned as Partial<SignedFederationUserProfile>).signature;
  if (!LoomNodeIdentity.verifyUtf8(payload(unsigned), input.signature, publicKey)) throw new Error('invalid_federation_user_signature');
  return {
    address,
    displayName: input.displayName,
    ...(input.avatar === undefined ? {} : { avatar: validateAvatar(input.avatar) }),
    identity: input.identity,
    devices,
    homeNode: {
      nodeId: input.homeNode.nodeId,
      domain: normalizeLoomDomain(input.homeNode.domain),
    },
    version: String(input.version),
    updatedAt: new Date(input.updatedAt).toISOString(),
  };
}
