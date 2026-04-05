class UserProfile {
  final String name;
  final String? avatarPath;

  const UserProfile({
    required this.name,
    this.avatarPath,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'avatarPath': avatarPath,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        name: json['name'] as String,
        avatarPath: json['avatarPath'] as String?,
      );
}
