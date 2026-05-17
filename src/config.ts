export const SITE = {
  website: "https://venkinotes.com/",
  author: "Venkatesh Periyathambi",
  profile: "https://venkinotes.com/",
  desc: "Notes on databases, data, and AI — views and customer problems from the field.",
  title: "Venki Notes",
  ogImage: "astropaper-og.jpg",
  lightAndDarkMode: true,
  postPerIndex: 4,
  postPerPage: 4,
  scheduledPostMargin: 15 * 60 * 1000, // 15 minutes
  showArchives: true,
  showBackButton: true,
  editPost: {
    enabled: false,
    text: "Edit page",
    url: "https://github.com/venkatesh-periyathambi/astrospace/edit/main/",
  },
  dynamicOgImage: true,
  dir: "ltr",
  lang: "en",
  timezone: "Europe/London",
} as const;
