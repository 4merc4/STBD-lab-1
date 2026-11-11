using EcommerceApp.Infrastructure;
using EcommerceApp.Models;

namespace EcommerceApp.Repositories;

public sealed class ReviewRepository : RepositoryBase, IReviewRepository
{
    public ReviewRepository(IDbSession session) : base(session) { }

    public Task<long> AddAsync(long userId, long productId, int rating, string? title, string? body)
        => CallForIdAsync("sp_review_add", userId, productId, rating, title, body);

    public Task SoftDeleteAsync(long reviewId) => CallAsync("sp_review_soft_delete", reviewId);

    public async Task<IReadOnlyList<ReviewDto>> GetForProductAsync(long productId)
        => await QueryAsync(
            @"SELECT review_id, product_id, product_name, user_id, reviewer_name, rating, title, body, created_at
                FROM v_reviews_active WHERE product_id = @id ORDER BY created_at DESC",
            r => new ReviewDto(r.Long("review_id"), r.Long("product_id"), r.Str("product_name"), r.Long("user_id"),
                               r.Str("reviewer_name"), r.Int("rating"), r.StrN("title"), r.StrN("body"),
                               r.Time("created_at")),
            ("id", productId));
}
