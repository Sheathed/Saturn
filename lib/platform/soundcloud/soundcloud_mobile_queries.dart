// Native SoundCloud GraphQL documents from the supplied Android capture.
const soundCloudFollowingFeedQuery = r'''
query FollowingFeed(
  $page: String
  $includePromoted: Boolean
  $includePlaylists: Boolean
  $consentParams: ConsentParams
  $first: Int
) {
  followingFeed(
    page: $page
    includePromoted: $includePromoted
    includePlaylists: $includePlaylists
    consentParams: $consentParams
  ) {
    items {
      ... on RepostedItem {
        __typename
        createdAt
        item {
          ...PlaylistFragment
          ...TrackFragment
        }
        reposter {
          ...UserFragment
        }
        caption
      }
      ... on PostedItem {
        __typename
        createdAt
        item {
          ...PlaylistFragment
          ...TrackFragment
        }
        caption
      }
      ... on PromotedItem {
        __typename
        promotedUrn
        createdAt
        item {
          ...PlaylistFragment
          ...TrackFragment
        }
        promoter {
          urn
          name
          avatarUrl
          verified
        }
        itemClickedUrls
        profileClickedUrls
        promoterClickedUrls
        itemPlayedUrls
        itemImpressionUrls
      }
    }
    page {
      nextPage
    }
  }
}

fragment UserFragment on User {
  urn
  name
  avatarUrl
  avatarUrlTemplate
  permalinkUrl
  city
  country
  countryCode
  createdAt
  description
  firstName
  lastName
  followersCount
  followingsCount
  tracksCount
  username
  verified
  stationUrns
  isPro
  playlistCount
  badges
  visualUrlTemplate
}

fragment TrackFragment on Track {
  __typename
  urn
  title
  public
  user {
    ...UserFragment
  }
  fullDuration
  snipDuration
  counts {
    plays
    likes
    reposts
    comments
  }
  transcodings {
    url
    uuid
    preset
    durationMs
    format {
      protocol
      mimeType
    }
    quality
    snipped
    type
    loudnessNormalization {
      inputI
      inputTp
      inputLra
      inputThreshold
      targetI
      targetTp
      targetLra
      targetThreshold
    }
  }
  transcodingSnips {
    url
    uuid
    preset
    durationMs
    format {
      protocol
      mimeType
    }
    quality
    snipped
    type
    loudnessNormalization {
      inputI
      inputTp
      inputLra
      inputThreshold
      targetI
      targetTp
      targetLra
      targetThreshold
    }
  }
  waveformUrl
  artworkUrlTemplate
  preview {
    startSeconds
    endSeconds
  }
  permalinkUrl
  commentable
  revealComments
  createdAt
  description
  genre
  secretToken
  displayStats
  userTags
  trackFormat
  authorization {
    monetizable
    snipped
    syncable
    subMidTier
    subHighTier
    policy
    externallyShareable
    blocked
    monetizationModel
  }
  stationUrns
  fpr
  isrc
}

fragment PlaylistFragment on Playlist {
  __typename
  urn
  playlistTitle: title
  artworkUrl
  releaseDate
  duration
  trackCount
  createdAt
  playlistCategory
  playlistUser: user {
    ...UserFragment
  }
  paginatedTracks(first: $first) {
    __typename
    pageInfo {
      nextPage
      hasNextPage
    }
    tracks {
      ...TrackFragment
    }
  }
}
''';

const soundCloudDiscoverFeedQuery = r'''
query DiscoverFeed {
  discoverFeed {
    items {
      event {
        ... on Track {
          __typename
          urn
          title
          public
          user {
            urn
            name
            avatarUrl
            avatarUrlTemplate
            permalinkUrl
            city
            country
            countryCode
            createdAt
            description
            firstName
            lastName
            followersCount
            followingsCount
            tracksCount
            username
            verified
            stationUrns
            isPro
            playlistCount
            badges
            visualUrlTemplate
          }
          fullDuration
          snipDuration
          counts {
            plays
            likes
            reposts
            comments
          }
          transcodings {
            url
            uuid
            preset
            durationMs
            format {
              protocol
              mimeType
            }
            quality
            snipped
            type
            loudnessNormalization {
              inputI
              inputTp
              inputLra
              inputThreshold
              targetI
              targetTp
              targetLra
              targetThreshold
            }
          }
          transcodingSnips {
            url
            uuid
            preset
            durationMs
            format {
              protocol
              mimeType
            }
            quality
            snipped
            type
            loudnessNormalization {
              inputI
              inputTp
              inputLra
              inputThreshold
              targetI
              targetTp
              targetLra
              targetThreshold
            }
          }
          waveformUrl
          artworkUrlTemplate
          preview {
            startSeconds
            endSeconds
          }
          permalinkUrl
          commentable
          revealComments
          createdAt
          description
          genre
          secretToken
          displayStats
          userTags
          trackFormat
          authorization {
            monetizable
            snipped
            syncable
            subMidTier
            subHighTier
            policy
            externallyShareable
            blocked
            monetizationModel
          }
          stationUrns
          fpr
          isrc
        }
      }
      seed {
        ... on Track {
          __typename
          urn
        }
      }
      reasonType
      reasonText
      iconUrl
      artworkUrl
      impressionId
    }
  }
}
''';
