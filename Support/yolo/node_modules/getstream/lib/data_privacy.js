"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.default = void 0;
exports.deleteActivities = deleteActivities;
exports.deleteReactions = deleteReactions;
exports.exportUserActivitiesAndReactionIDs = exportUserActivitiesAndReactionIDs;
function deleteActivities(activities) {
  this._throwMissingApiSecret();
  return this.post({
    url: 'data_privacy/delete_activities/',
    body: {
      activities: activities
    },
    token: this.getOrCreateToken()
  });
}
function deleteReactions(ids) {
  this._throwMissingApiSecret();
  return this.post({
    url: 'data_privacy/delete_reactions/',
    body: {
      ids: ids
    },
    token: this.getOrCreateToken()
  });
}
function exportUserActivitiesAndReactionIDs(userId) {
  if (!userId) {
    throw new Error("User ID can't be null or empty");
  }
  return this.get({
    url: "data_privacy/export_ids/".concat(userId),
    token: this.getOrCreateToken()
  });
}
var _default = exports.default = {
  deleteActivities: deleteActivities,
  deleteReactions: deleteReactions,
  exportUserActivitiesAndReactionIDs: exportUserActivitiesAndReactionIDs
};