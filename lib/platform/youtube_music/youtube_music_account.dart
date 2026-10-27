class YouTubeMusicAccount {
  const YouTubeMusicAccount({
    required this.name,
    this.email,
    this.channelHandle,
    this.photoUrl,
  });

  final String name;
  final String? email;
  final String? channelHandle;
  final String? photoUrl;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (email != null) 'email': email,
        if (channelHandle != null) 'channelHandle': channelHandle,
        if (photoUrl != null) 'photoUrl': photoUrl,
      };

  factory YouTubeMusicAccount.fromJson(Map<String, dynamic> json) =>
      YouTubeMusicAccount(
        name: json['name'] as String? ?? 'YouTube Music User',
        email: json['email'] as String?,
        channelHandle: json['channelHandle'] as String?,
        photoUrl: json['photoUrl'] as String?,
      );

  @override
  String toString() =>
      'YouTubeMusicAccount(name: $name, email: $email, handle: $channelHandle)';
}
